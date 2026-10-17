#!/usr/bin/env python3
"""Weekly capacity digest of this box, sent to Telegram.

Cron runs it on each box on Monday at 13:00 UTC (scripts/capacity.cron). It
reads the local Prometheus, adds one row to the history file, finds how many
weeks are left before each limit reaches its warn level and sends one plain
text message. docs/capacity.md tells how to read the digest.

The digest runs on the box, not in GitHub Actions: it uses the local
Prometheus and the Telegram keys that Grafana already has in .env, it needs
no new secret and no SSH key, and it works when GitHub is down. Because it
uses the same Telegram bot as the alerts, it is also a weekly heartbeat of
the alert path.

Usage: capacity-report.py [--dry-run]
  --dry-run  print the message. Send nothing, and write no history row and
             no success metric.

For tests: PROM_URL (query this URL directly, not through nsenter),
TELEGRAM_API, ENV_FILE, CAPACITY_STATE_DIR, TEXTFILE_DIR and NOW (a Unix
time for the report).
"""

import argparse
import csv
import datetime
import json
import math
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ENV_FILE = os.environ.get("ENV_FILE", "/opt/monero-node/.env")
STATE_DIR = os.environ.get("CAPACITY_STATE_DIR", "/var/lib/monero-node-capacity")
TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node-exporter/textfile")
TELEGRAM_API = os.environ.get("TELEGRAM_API", "https://api.telegram.org")
PROM_URL = os.environ.get("PROM_URL", "")
HISTORY = os.path.join(STATE_DIR, "history.csv")
HISTORY_ROWS = 104
TELEGRAM_MAX = 4096

# The monero-exporter calls these methods on the unrestricted RPC. They do
# not load the 2 threads of the public RPC (same list as capacity-rules.yml).
EXPORTER = ("get_connections|get_peer_list|get_net_stats|get_transaction_pool|"
            "get_transaction_pool_stats|rpc_access_tracking|get_block|get_last_block_header")
SUB = '{server="restricted"}'

COLUMNS = [
    "week_end", "rpc_public_peak", "rpc_total_peak", "limit_total", "onion_peak", "limit_private",
    "ip_max_peak", "limit_public", "ip_minutes_at_cap", "churn_ip_minutes", "busy_peak", "busy_avg",
    "socket_hours_per_day", "egress_week", "egress_mtd", "egress_projection", "included", "disk_used",
    "monerod_cpu_peak", "monerod_anon_peak", "fds_peak",
]

# Limits for "weeks to warn level": (label, value column, limit column or a number)
TRENDS = [
    ("sockets", "rpc_total_peak", "limit_total"),
    ("Tor", "onion_peak", "limit_private"),
    ("per-IP", "ip_max_peak", "limit_public"),
    ("RPC threads", "busy_peak", 1.0),
    ("traffic", "egress_projection", "included"),
]
WARN_LEVEL = 0.8


class Failure(Exception):
    """A failure with a short reason that is safe to print and to send."""


def read_env(path, keys):
    """Reads only the given keys from a KEY=VALUE file."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.startswith("export "):
                    k = k[len("export "):].strip()
                if k in keys:
                    out[k] = v.strip().strip("'\"")
    except OSError as e:
        raise Failure(f"cannot read {path} ({e.strerror})") from None
    return out


class Prometheus:
    def __init__(self):
        self.pid = None
        self.errors = 0
        if not PROM_URL:
            try:
                r = subprocess.run(["docker", "inspect", "-f", "{{.State.Pid}}", "prometheus"],
                                   capture_output=True, text=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired) as e:
                raise Failure(f"docker inspect failed ({type(e).__name__})") from None
            pid = r.stdout.strip()
            if r.returncode != 0 or not pid.isdigit() or pid == "0":
                raise Failure("the prometheus container is not running")
            self.pid = pid

    def _get(self, expr):
        if PROM_URL:
            url = PROM_URL.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
            with urllib.request.urlopen(url, timeout=90) as r:
                return r.read()
        r = subprocess.run(["nsenter", "-t", self.pid, "-n", "curl", "-s", "-G", "-m", "90",
                            "http://127.0.0.1:9091/api/v1/query", "--data-urlencode", "query=" + expr],
                           capture_output=True, timeout=120, check=False)
        if r.returncode != 0:
            raise OSError(f"curl exit {r.returncode}")
        return r.stdout

    def query(self, expr, strict=False):
        """Returns the result vector. strict: a failure stops the digest."""
        try:
            body = json.loads(self._get(expr))
            if body.get("status") != "success":
                raise ValueError(body.get("errorType", "error"))
            res = body["data"]["result"]
            if body["data"].get("resultType") == "scalar":
                res = [{"metric": {}, "value": res}]
            return res
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as e:
            if strict:
                raise Failure(f"Prometheus query failed ({type(e).__name__})") from None
            self.errors += 1
            return []

    def value(self, expr):
        """The first value of the result, or None."""
        for r in self.query(expr):
            v = float(r["value"][1])
            if math.isfinite(v):
                return v
        return None

    def by(self, expr, label):
        """label value -> number, for each series of the result."""
        out = {}
        for r in self.query(expr):
            v = float(r["value"][1])
            if math.isfinite(v):
                out[r["metric"].get(label, "")] = v
        return out


def collect(p, box):
    x = EXPORTER
    v = p.value
    d = {}
    d["rpc_public_peak"] = v(f'max_over_time(sum(capacity_rpc_connections{{server="restricted",source="public"}})[7d:1m])')
    d["rpc_public_avg"] = v(f'avg_over_time(sum(capacity_rpc_connections{{server="restricted",source="public"}})[7d:1m])')
    d["rpc_total_peak"] = v('max_over_time(sum(capacity_rpc_connections{server="restricted"})[7d:1m])')
    d["onion_peak"] = v('max_over_time(max(capacity_rpc_connections{server="restricted",source="onion"})[7d:1m])')
    lim = p.by("max by (kind) (capacity_rpc_limit)", "kind")
    d["limit_total"], d["limit_public"], d["limit_private"] = lim.get("total"), lim.get("public_ip"), lim.get("private_ip")
    d["ip_max_peak"] = v(f"max_over_time(max(capacity_rpc_public_max_per_ip{SUB})[7d:1m])")
    d["ip_minutes_at_cap"] = v(f"sum_over_time(max(capacity_rpc_public_ips_at_cap{SUB})[7d:1m])")
    d["churn_ip_minutes"] = v(f"sum_over_time(max(capacity_rpc_churn_ips{SUB})[7d:1m])")
    d["busy_peak"] = v(f'max_over_time((sum(rate(monero_rpc_seconds_total{{method!~"{x}"}}[5m])) / 2)[7d:5m])')
    d["busy_avg"] = v(f'sum(increase(monero_rpc_seconds_total{{method!~"{x}"}}[7d])) / 604800 / 2')
    d["calls"] = p.by(f'topk(6, sum by (method) (increase(monero_rpc_hits_total{{method!~"{x}"}}[7d])) / 7)', "method")
    d["new_conns"] = p.by("sum by (port) (increase(capacity_new_connections_total[7d])) / 7", "port")
    probes = {}
    for r in p.query("avg by (job, node) (avg_over_time(probe_success[7d]))"):
        val = float(r["value"][1])
        if math.isfinite(val):
            probes.setdefault(r["metric"].get("node", "?"), {})[r["metric"].get("job", "?")] = val
    d["probes"] = probes
    d["p95"] = p.by('max by (node) (quantile_over_time(0.95, probe_duration_seconds{job="rpc"}[7d]))', "node")
    d["egress_week"] = v('sum(increase(capacity_host_network_bytes_total{direction="tx"}[7d]))')
    d["egress_mtd"] = v("max(capacity_host_tx_month_bytes)")
    d["included"] = v("max(capacity_traffic_included_bytes)")
    d["egress_by"] = p.by('sum by (container) (increase(capacity_netns_network_bytes_total{direction="tx",network="public"}[7d]))', "container")
    d["tor_clients_peak"] = v("max_over_time(sum(tor_hs_rdv_established_count)[7d:1m])")
    d["tor_rdv_errors"] = v("sum(increase(tor_hs_rdv_error_count[7d]))")
    d["tor_intro_rejects"] = v("sum(increase(tor_hs_intro_rejected_intro_req_count[7d]))")
    d["p2p"] = p.by("max by (direction) (max_over_time(capacity_p2p_connections[7d]))", "direction")
    d["monerod_cpu_peak"] = v('max_over_time(rate(capacity_cgroup_cpu_usage_seconds_total{container="monerod"}[5m])[7d:5m])')
    d["cpu_limit"] = v('max(capacity_cgroup_cpu_limit_cores{container="monerod"})')
    d["throttled"] = v('sum(increase(capacity_cgroup_cpu_throttled_periods_total{container="monerod"}[7d])) / '
                       'sum(increase(capacity_cgroup_cpu_periods_total{container="monerod"}[7d]))')
    d["monerod_anon_peak"] = v('max(max_over_time(capacity_cgroup_memory_anon_bytes{container="monerod"}[7d]))')
    d["mem_limit"] = v('max(capacity_cgroup_memory_limit_bytes{container="monerod"})')
    d["fds_peak"] = v('max(max_over_time(capacity_process_open_fds{container="monerod"}[7d]))')
    d["fd_limit"] = v('max(capacity_process_fd_soft_limit{container="monerod"})')
    d["pids_peak"] = v('max(max_over_time(capacity_cgroup_pids{container="monerod"}[7d]))')
    d["pids_limit"] = v('max(capacity_cgroup_pids_limit{container="monerod"})')
    d["host_cpu_peak"] = v('max_over_time((1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))[7d:5m])')
    d["ram_min"] = v("min(min_over_time(node_memory_MemAvailable_bytes[7d]))")
    root = 'mountpoint="/"'
    d["disk_avail"] = v(f"max(node_filesystem_avail_bytes{{{root}}})")
    d["disk_size"] = v(f"max(node_filesystem_size_bytes{{{root}}})")
    d["disk_deriv"] = v(f"max(deriv(node_filesystem_avail_bytes{{{root}}}[7d]))")
    d["aborts"] = v('sum(increase(capacity_netns_tcpext_total{container="monerod",counter=~"TCPAbortOnClose|TCPAbortOnData"}[7d])) / 7')
    d["uptime"] = v("max(monero_info_uptime_seconds_total)")
    d["restarts"] = v('max(changes(capacity_container_start_time_seconds{container="monerod"}[7d]))')
    d["box"] = box
    return d


def derive(d, now):
    """Adds the values that the history and the message need."""
    t = datetime.datetime.fromtimestamp(now, datetime.timezone.utc)
    start = datetime.datetime(t.year, t.month, 1, tzinfo=datetime.timezone.utc)
    nxt = datetime.datetime(t.year + (t.month == 12), t.month % 12 + 1, 1, tzinfo=datetime.timezone.utc)
    frac = (t - start).total_seconds() / (nxt - start).total_seconds()
    mtd = d.get("egress_mtd")
    # Early in the month the pace is not stable, so give no projection before day 4
    d["egress_projection"] = mtd / frac if mtd is not None and t.day >= 4 and frac > 0 else None
    avg = d.get("rpc_public_avg")
    d["socket_hours_per_day"] = avg * 24 if avg is not None else None
    if d.get("disk_avail") is not None and d.get("disk_size"):
        d["disk_used"] = 1 - d["disk_avail"] / d["disk_size"]
    else:
        d["disk_used"] = None
    d["week_end"] = t.strftime("%Y-%m-%d")
    d["week_start"] = (t - datetime.timedelta(days=7)).strftime("%Y-%m-%d")
    return d


def read_history():
    try:
        with open(HISTORY, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))
    except OSError:
        return []


def history_with(rows, d):
    """The history with the row of this week. A second run on the same day
    replaces that day's row."""
    row = {c: "" if d.get(c) is None else (d[c] if c == "week_end" else f"{d[c]:.6g}") for c in COLUMNS}
    rows = [r for r in rows if r.get("week_end") != row["week_end"]] + [row]
    return rows[-HISTORY_ROWS:]


def write_history(rows):
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".history.")
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    os.chmod(tmp, 0o644)
    os.replace(tmp, HISTORY)


def num(r, key):
    try:
        v = float(r.get(key, ""))
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def weeks_to_warn(rows, col, limit):
    """Weeks until the value reaches WARN_LEVEL x limit, from a least-squares
    line through the last 3 to 8 rows. "flat" means more than 2 years."""
    pts = []
    for r in rows[-8:]:
        y = num(r, col)
        lim = limit if isinstance(limit, float) else num(r, limit)
        try:
            day = datetime.date.fromisoformat(r.get("week_end", ""))
        except ValueError:
            continue
        if y is not None and lim:
            pts.append((day.toordinal() / 7.0, y, lim))
    if len(pts) < 3:
        return "needs 3 weeks of data"
    n = len(pts)
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    slope = sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx if sxx else 0.0
    newest, warn = pts[-1][1], WARN_LEVEL * pts[-1][2]
    if newest >= warn:
        return "now"
    weeks = (warn - newest) / slope if slope > 0 else math.inf
    if weeks > HISTORY_ROWS:
        return "flat"
    return f"{weeks:.0f}"


# ---- formatting

def n0(v):
    return "n/a" if v is None else f"{v:,.0f}"


def f1(v, unit=""):
    return "n/a" if v is None else f"{v:.1f}{unit}"


def pct(v, digits=0):
    return "n/a" if v is None else f"{v * 100:.{digits}f}%"


def gb(v):
    return "n/a" if v is None else f"{v / 1e9:,.0f} GB"


def of(v, limit):
    """"12 of 100 (12%)", or "12" when the limit is unknown."""
    if v is None:
        return "n/a"
    if not limit:
        return n0(v)
    return f"{n0(v)} of {n0(limit)} ({pct(v / limit)})"


def days_to(d, level):
    avail, size, deriv = d.get("disk_avail"), d.get("disk_size"), d.get("disk_deriv")
    if avail is None or not size or deriv is None:
        return "n/a"
    left = avail - (1 - level) * size
    if left <= 0:
        return "now"
    if deriv >= 0:
        return "not filling"
    return f"in {left / -deriv / 86400:,.0f} d"


def message(d, rows, prom_errors):
    box = d["box"]
    lines = [f"monero-node weekly: {box} ({d['week_start']} to {d['week_end']})", ""]
    lines.append(f"RPC sockets: peak {of(d.get('rpc_total_peak'), d.get('limit_total'))}. "
                 f"Clearnet wallets: peak {n0(d.get('rpc_public_peak'))}, avg {f1(d.get('rpc_public_avg'))}, "
                 f"{n0(d.get('socket_hours_per_day'))} socket-hours/day")
    lines.append(f"Tor sockets: peak {of(d.get('onion_peak'), d.get('limit_private'))}. "
                 f"Tor clients peak {n0(d.get('tor_clients_peak'))}. Tor errors {n0(d.get('tor_rdv_errors'))}, "
                 f"intro rejects {n0(d.get('tor_intro_rejects'))}")
    lines.append(f"Busiest public IP: {of(d.get('ip_max_peak'), d.get('limit_public'))}. "
                 f"IP-minutes at cap: {n0(d.get('ip_minutes_at_cap'))}. "
                 f"Reconnecting IP-minutes: {n0(d.get('churn_ip_minutes'))}")
    p95 = d.get("p95", {})
    probe = ", ".join(f"{k.upper()} {v * 1000:.0f} ms" for k, v in sorted(p95.items(), key=lambda kv: (kv[0] != box.lower(), kv[0])))
    lines.append(f"RPC threads: peak {pct(d.get('busy_peak'))} (5 min), avg {pct(d.get('busy_avg'), 1)}. "
                 f"RPC probe p95 from this box: {probe or 'n/a'}")
    calls = sorted(d.get("calls", {}).items(), key=lambda kv: -kv[1])
    lines.append("Calls/day: " + (", ".join(f"{k} {n0(v)}" for k, v in calls) or "n/a"))
    conns = sorted(d.get("new_conns", {}).items(), key=lambda kv: -kv[1])
    lines.append("New connections/day: " + (", ".join(f"{k} {n0(v)}" for k, v in conns) or "n/a"))
    proj, inc = d.get("egress_projection"), d.get("included")
    if proj is None:
        projected = "no projection before day 4"
    elif inc:
        projected = f"projected {n0(proj / 1e9)} of {n0(inc / 1e9)} GB ({pct(proj / inc)})"
    else:
        projected = f"projected {gb(proj)}"
    lines.append(f"Egress: week {gb(d.get('egress_week'))}, month {gb(d.get('egress_mtd'))}, {projected}")
    by = sorted(d.get("egress_by", {}).items(), key=lambda kv: -kv[1])
    if by:
        lines.append("Egress by container (week): " + ", ".join(f"{k} {gb(v)}" for k, v in by[:5]))
    p2p = d.get("p2p", {})
    lines.append(f"P2P peers: in {n0(p2p.get('in'))}, out {n0(p2p.get('out'))}")
    anon, mem = d.get("monerod_anon_peak"), d.get("mem_limit")
    memory = "n/a" if anon is None else f"{anon / 2**30:.1f}" + (f" of {mem / 2**30:.0f} GiB" if mem else " GiB")
    cpu, cpul = d.get("monerod_cpu_peak"), d.get("cpu_limit")
    cpus = "n/a" if cpu is None else f"{cpu:.1f}" + (f" of {cpul:.0f} cores" if cpul else " cores")
    lines.append(f"monerod: CPU peak {cpus}, throttled {pct(d.get('throttled'), 1)}, memory {memory}, "
                 f"fds {n0(d.get('fds_peak'))} of {n0(d.get('fd_limit'))}, "
                 f"threads {n0(d.get('pids_peak'))} of {n0(d.get('pids_limit'))}")
    ram = d.get("ram_min")
    lines.append(f"Host: CPU peak {pct(d.get('host_cpu_peak'))}, RAM free min "
                 f"{f1(None if ram is None else ram / 2**30, ' GiB')}, disk {pct(d.get('disk_used'))} "
                 f"(80% {days_to(d, 0.8)}, 85% {days_to(d, 0.85)})")
    parts = []
    for node in sorted(d.get("probes", {}), key=lambda n: (n != box.lower(), n)):
        jobs = d["probes"][node]
        parts.append(node.upper() + " " + ", ".join(f"{j} {pct(jobs[j], 1)}" for j in sorted(jobs)))
    lines.append("Probes from this box: " + (". ".join(parts) or "n/a"))
    up = d.get("uptime")
    lines.append(f"monerod: up {f1(None if up is None else up / 86400, ' d')}, "
                 f"restarts this week {n0(d.get('restarts'))}, TCP aborts/day {n0(d.get('aborts'))}")
    lines.append("")
    weeks = [(label, weeks_to_warn(rows, col, lim)) for label, col, lim in TRENDS]
    if all(w == "needs 3 weeks of data" for _, w in weeks):
        lines.append("Weeks to warn level (80% of the limit): needs 3 weeks of data")
    else:
        lines.append("Weeks to warn level (80% of the limit): " + ", ".join(f"{label} {w}" for label, w in weeks))
    if len(rows) >= 2:
        prev, cur = rows[-2], rows[-1]
        ch = []
        a, b = num(prev, "rpc_total_peak"), num(cur, "rpc_total_peak")
        if a is not None and b is not None:
            ch.append(f"socket peak {b - a:+.0f}")
        a, b = num(prev, "egress_week"), num(cur, "egress_week")
        if a and b is not None:
            ch.append(f"egress {(b - a) / a * 100:+.0f}%")
        if ch:
            lines.append("Change vs last week: " + ", ".join(ch))
    if prom_errors:
        lines.append(f"{prom_errors} queries failed. Their lines show n/a.")
    lines.append("")
    lines.append(f"Heartbeat: the {box} box sends this digest every Monday at 13:00 UTC through the "
                 "Telegram bot of its alerts. When it does not arrive, the alert path of this box "
                 "is broken. Check Grafana and the cron on the box.")
    text = "\n".join(lines)
    return text if len(text) <= TELEGRAM_MAX else text[:TELEGRAM_MAX - 2] + "\n…"


def send(text, token, chat):
    url = f"{TELEGRAM_API.rstrip('/')}/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat, "text": text, "disable_web_page_preview": "true"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as r:
            ok = json.loads(r.read()).get("ok")
    except urllib.error.HTTPError as e:
        # Never print the URL: it holds the bot token
        raise Failure(f"Telegram refused the message (HTTP {e.code})") from None
    except (OSError, ValueError) as e:
        raise Failure(f"Telegram send failed ({type(e).__name__})") from None
    if not ok:
        raise Failure("Telegram did not accept the message")


def write_success(now):
    os.makedirs(TEXTFILE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=TEXTFILE_DIR, prefix=".capacity-report.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("# HELP capacity_report_last_success_timestamp_seconds Time of the last weekly digest that Telegram accepted.\n")
        f.write("# TYPE capacity_report_last_success_timestamp_seconds gauge\n")
        f.write(f"capacity_report_last_success_timestamp_seconds {int(now)}\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(TEXTFILE_DIR, "capacity-report.prom"))


def main():
    ap = argparse.ArgumentParser(description="Weekly capacity digest of this box.")
    ap.add_argument("--dry-run", action="store_true", help="print the message, send nothing, write nothing")
    args = ap.parse_args()
    now = float(os.environ.get("NOW") or datetime.datetime.now(datetime.timezone.utc).timestamp())

    try:
        env = read_env(ENV_FILE, {"TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "DOMAIN"})
    except Failure as e:
        print(f"capacity-report: {e}", file=sys.stderr)
        return 1
    # DOMAIN names the box (us.node.monero.one -> US). It is not a secret.
    box = (env.get("DOMAIN") or "unknown").split(".")[0].upper()
    token, chat = env.get("TELEGRAM_BOT_TOKEN"), env.get("TELEGRAM_CHAT_ID")
    if not args.dry_run and not (token and chat):
        print("capacity-report: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is missing in " + ENV_FILE, file=sys.stderr)
        return 1

    try:
        p = Prometheus()
        p.query("up", strict=True)
        d = derive(collect(p, box), now)
    except Failure as e:
        text = f"monero-node weekly: {box}: digest failed ({e})"
        print(text, file=sys.stderr)
        if not args.dry_run:
            try:
                send(text, token, chat)
            except Failure as e2:
                print(f"capacity-report: {e2}", file=sys.stderr)
        return 1

    rows = history_with(read_history(), d)
    text = message(d, rows, p.errors)
    if args.dry_run:
        print(text)
        return 0
    try:
        send(text, token, chat)
    except Failure as e:
        print(f"capacity-report: {e}", file=sys.stderr)
        return 1
    write_history(rows)
    write_success(now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
