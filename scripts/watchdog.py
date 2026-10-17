#!/usr/bin/env python3
"""External watchdog for both boxes.

GitHub Actions runs it every 10 minutes (.github/workflows/watchdog.yml),
when an AWS EventBridge rule dispatches the workflow (scripts/watchdog-clock.sh).
From outside, it checks on each box: get_info over TLS on the public RPC
ports, whether the height is current, Grafana /api/health, and the onion
over Tor (plain HTTP and TLS). A check fails only when it fails for about
2 minutes, with a new try every 15 seconds.

The boxes alert on their own services, and each box watches the Grafana of
the other box. So the watchdog sends only what the boxes cannot send:
  - the failed checks of a box whose Grafana does not answer from outside,
    when the Grafana of the other box does not answer either, or after
    30 minutes (the other box sends Grafana Unreachable first)
One Telegram message per run holds the new failures, the reminders (every
4 hours) and the recoveries. docs/monitoring.md explains the checks.

Telegram is on only when WATCHDOG_LIVE is 1 (a repository variable). Else
each run writes the checks to the job summary, with the message that a live
run sends. It marks nothing as sent, so a failure that lasts until Telegram
is on goes out as new in the first live run.

The run logs are public. This script prints no IPs, no tokens, no chat ID,
no onion names and no response bodies. A curl error shows as a short name
(timeout, connection refused), never as curl text, which can hold an IP.

Usage: watchdog.py --state FILE [--tor-container NAME] [--socks ADDR] [--dry-run]
Environment: WATCHDOG_LIVE, TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (needed
only when WATCHDOG_LIVE is 1), GITHUB_STEP_SUMMARY (set by GitHub). For tests:
TELEGRAM_API, WATCHDOG_TARGETS (JSON in place of monitoring/prometheus.yml),
WATCHDOG_CONTROL_URL, WATCHDOG_BUDGET, WATCHDOG_RETRY_WAIT and NOW.
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TELEGRAM_API = os.environ.get("TELEGRAM_API", "https://api.telegram.org")
CONTROL_URL = os.environ.get("WATCHDOG_CONTROL_URL", "https://api.github.com")
BUDGET = float(os.environ.get("WATCHDOG_BUDGET", "120"))  # seconds of tries per check
RETRY_WAIT = float(os.environ.get("WATCHDOG_RETRY_WAIT", "15"))
TOR_WAIT = 150  # seconds for Tor on the runner to bootstrap
REMIND = 4 * 3600 - 300  # a run can start some minutes early or late
GRAFANA_GRACE = 30 * 60  # the other box alerts first; the watchdog after this
HEIGHT_LAG = 10  # blocks behind the other box
HEIGHT_STALE = 60 * 60  # seconds with no new block; a block comes about every 2 minutes
STATE_VERSION = 1
NO_TOR = "Tor on the runner did not start"

# Curl exit codes as short names. Curl error text can hold an IP, so the
# script never prints it.
CURL_ERRORS = {
    5: "proxy name not resolved", 6: "name not resolved", 7: "connection refused or unreachable",
    28: "timeout", 35: "TLS handshake failed", 52: "empty reply", 56: "connection reset",
    60: "cert not valid", 97: "Tor proxy error",
}


def log(msg):
    print(msg, flush=True)


# ---- targets

def targets_from_prometheus(path):
    """Box name -> its URLs, from the probe jobs in monitoring/prometheus.yml."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    boxes = {}
    for job in re.split(r"\n\s*- job_name:", text)[1:]:
        name = re.match(r'\s*"?([\w-]+)"?', job).group(1)
        body = job.split("relabel_configs", 1)[0]
        for group in body.split("- targets:")[1:]:
            urls = re.findall(r"""(https?://[^\s"',\]]+)""", group)
            node = re.search(r"\bnode:\s*(\w+)", group)
            domain = re.search(r"\bdomain:\s*([\w.-]+)", group)
            if not urls or not node:
                continue
            b = boxes.setdefault(node.group(1), {"rpc": []})
            if domain:
                b["domain"] = domain.group(1)
            if name == "rpc":
                # get_info has the height and the sync state. Same host and port.
                b["rpc"] += [re.sub(r"/get_height$", "/get_info", u) for u in urls]
            elif name in ("onion", "onion-tls", "grafana"):
                b[name.replace("-", "_")] = urls[0]
    return boxes


def load_targets():
    if os.environ.get("WATCHDOG_TARGETS"):
        return json.loads(os.environ["WATCHDOG_TARGETS"])
    return targets_from_prometheus(os.path.join(ROOT, "monitoring", "prometheus.yml"))


def port_of(url):
    p = urllib.parse.urlsplit(url)
    return str(p.port or (443 if p.scheme == "https" else 80))


# ---- checks

def fetch(url, timeout, socks=None, insecure=False):
    """(HTTP code, body), or (None, short error)."""
    cmd = ["curl", "-s", "-o", "-", "-w", "\n%{http_code}", "--max-time", str(int(timeout)),
           "--connect-timeout", str(int(min(timeout, 30))), "--proto", "=http,https", url]
    if socks:
        cmd += ["--socks5-hostname", socks]
    if insecure:
        cmd += ["-k"]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout + 15, check=False)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if r.returncode != 0:
        return None, CURL_ERRORS.get(r.returncode, f"curl error {r.returncode}")
    body, _, code = r.stdout.rpartition(b"\n")
    try:
        return int(code), body
    except ValueError:
        return None, "bad reply"


def check_rpc(url, timeout=20, socks=None, insecure=False):
    """Passes on HTTP 200 with JSON status OK. The data is the JSON."""
    code, body = fetch(url, timeout, socks, insecure)
    if code is None:
        return False, body, None
    if code != 200:
        return False, f"HTTP {code}", None
    try:
        d = json.loads(body)
    except ValueError:
        d = None
    if not isinstance(d, dict) or d.get("status") != "OK":
        return False, "reply without status OK", None
    return True, "", d


def check_grafana(url, timeout=20):
    code, body = fetch(url, timeout)
    if code is None:
        return False, body, None
    if code != 200:
        return False, f"HTTP {code}", None
    try:
        ok = json.loads(body).get("database") == "ok"
    except (ValueError, AttributeError):
        ok = False
    return (True, "", None) if ok else (False, "database not ok", None)


def check_control(url):
    """Any HTTP reply shows that the runner has a network."""
    code, body = fetch(url, 20)
    return (code is not None), ("" if code is not None else body), None


def retry(fn, *args, **kw):
    """Calls fn until it passes or the time budget is used up."""
    start = time.monotonic()
    attempts = 0
    while True:
        attempts += 1
        ok, detail, data = fn(*args, **kw)
        if ok or time.monotonic() - start + RETRY_WAIT >= BUDGET:
            return ok, detail, data, attempts
        time.sleep(RETRY_WAIT)


def wait_for_tor(container):
    """True when Tor on the runner has bootstrapped. The script only looks
    for one string in the Tor log, and never prints the log."""
    if not container:
        return True
    deadline = time.monotonic() + TOR_WAIT
    while time.monotonic() < deadline:
        r = subprocess.run(["docker", "logs", container], capture_output=True, text=True, check=False)
        if r.returncode != 0:
            return False
        if "Bootstrapped 100%" in r.stdout + r.stderr:
            return True
        time.sleep(3)
    return False


def run_checks(boxes, socks, tor_container):
    """Check id -> (status, detail, data). The status is ok, fail or unknown."""
    results = {}
    jobs = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        tor = ex.submit(wait_for_tor, tor_container)

        def onion(url, insecure):
            if not tor.result():
                return False, NO_TOR, None, 0
            # The TLS cert of the onion names the domain, not the onion
            return retry(check_rpc, url, timeout=60, socks=socks, insecure=insecure)

        for box, t in boxes.items():
            for url in t.get("rpc", []):
                jobs[f"{box}-rpc-{port_of(url)}"] = ex.submit(retry, check_rpc, url)
            if t.get("grafana"):
                jobs[f"{box}-grafana"] = ex.submit(retry, check_grafana, t["grafana"])
            if t.get("onion"):
                jobs[f"{box}-onion"] = ex.submit(onion, t["onion"], False)
            if t.get("onion_tls"):
                jobs[f"{box}-onion-tls"] = ex.submit(onion, t["onion_tls"], True)
        for cid, fut in jobs.items():
            ok, detail, data, attempts = fut.result()
            status = "unknown" if detail == NO_TOR else ("ok" if ok else "fail")
            results[cid] = (status, detail, data)
            log(f"{cid}: {status}{f' ({detail})' if detail else ''}, {attempts} tries")
    return results


def height_checks(boxes, results, state, now):
    """Adds <box>-height from the get_info replies of the RPC checks."""
    info = {}
    for box in boxes:
        for cid in sorted(c for c in results if c.startswith(f"{box}-rpc-")):
            st, _, data = results[cid]
            if st == "ok" and data:
                info[box] = data
                break
    heights = state.setdefault("heights", {})
    for box in boxes:
        cid = f"{box}-height"
        d = info.get(box)
        if d is None:
            results[cid] = ("unknown", "no RPC reply", None)
            log(f"{cid}: unknown (no RPC reply)")
            continue
        h = int(d.get("height") or 0)
        problems = []
        if not d.get("synchronized"):
            problems.append("not synchronized")
        if d.get("busy_syncing"):
            problems.append("busy syncing")
        for b, other in sorted(info.items()):
            oh = int(other.get("height") or 0)
            if b != box and h < oh - HEIGHT_LAG:
                problems.append(f"{oh - h} blocks behind the {b.upper()} box")
        prev = heights.get(box) or {}
        if prev.get("height") != h:
            heights[box] = prev = {"height": h, "changed_at": now}
        if now - prev["changed_at"] >= HEIGHT_STALE:
            problems.append(f"no new block for {int((now - prev['changed_at']) / 60)} minutes")
        detail = ", ".join(problems)
        results[cid] = ("fail" if problems else "ok", detail, None)
        log(f"{cid}: {results[cid][0]}{f' ({detail})' if detail else ''}")


# ---- what to send

def kind_of(cid):
    box, rest = cid.split("-", 1)
    return box, re.sub(r"^rpc-\d+$", "rpc", rest)


def describe(cid, detail, results):
    """(what broke, who is affected, first step) of a failed check."""
    box, kind = kind_of(cid)
    b = box.upper()
    why = f" ({detail})" if detail else ""
    if kind == "rpc":
        port = cid.rsplit("-", 1)[1]
        return (f"The clearnet RPC on port {port} fails from outside{why}.",
                f"Clearnet RPC users of the {b} box",
                f"On the {b} box run docker compose ps monerod and docker logs --tail 50 monerod.")
    if kind == "height":
        return (f"monerod does not have the current chain: {detail}.",
                f"Clearnet RPC users and onion users of the {b} box. Their wallets show old data.",
                f"On the {b} box run docker logs --tail 50 monerod.")
    if kind == "grafana":
        rpc = [c for c in results if c.startswith(f"{box}-rpc-")]
        down = rpc and all(results[c][0] == "fail" for c in rpc)
        return (f"Grafana on the {b} box does not answer from outside{why}, so this box cannot send alerts.",
                f"All users of the {b} box: its RPC also fails from outside." if down else
                f"Monitoring only. The {b} box cannot send its alerts.",
                f"On the {b} box run docker compose ps. When ssh to the box fails, look at it in the Hetzner console.")
    tls = kind == "onion-tls"
    return (f"The onion fails over {'TLS' if tls else 'plain HTTP'} through Tor{why}.",
            f"Onion users of the {b} box" + (" that connect with https" if tls else ""),
            f"On the {b} box run docker compose ps tor onion-proxy and docker logs --tail 50 tor.")


CLEARED_TEXT = {
    "rpc": "The clearnet RPC on port {port} works again.",
    "height": "monerod has the current chain again.",
    "grafana": "Grafana on the {b} box answers again.",
    "onion": "The onion works again over plain HTTP.",
    "onion-tls": "The onion works again over TLS.",
}


def hhmm(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")


def covered(cid, checks, grafana_ok, now):
    """True while a box sends the alert for this failure."""
    box, kind = kind_of(cid)
    if kind != "grafana" and grafana_ok.get(box):
        return True  # the box alerts on its own services
    # The Grafana of this box does not answer. The other box sends Grafana
    # Unreachable, with the state of the RPC and the onion of this box.
    peer_ok = any(ok for b, ok in grafana_ok.items() if b != box)
    since = checks.get(f"{box}-grafana", {}).get("since", now)
    return peer_ok and now - since < GRAFANA_GRACE


def decide(results, state, now):
    """Updates the state. Returns (new, reminders, cleared)."""
    checks = state.setdefault("checks", {})
    for cid in [c for c in checks if c not in results]:
        del checks[cid]  # its target is no longer in prometheus.yml
    boxes = {kind_of(c)[0] for c in results}
    grafana_ok = {b: results.get(f"{b}-grafana", ("unknown",))[0] == "ok" for b in boxes}
    for cid in sorted(results):
        status, detail, _ = results[cid]
        if status == "fail":
            st = checks.get(cid) or {"since": now}
            st["detail"] = detail
            checks[cid] = st
    new, remind, cleared = [], [], []
    for cid in sorted(results):
        status = results[cid][0]
        st = checks.get(cid)
        if status == "unknown" or st is None:
            continue  # an unknown check keeps its state
        if status == "ok":
            if st.get("sent"):
                cleared.append((cid, st))
            del checks[cid]
            continue
        st["covered"] = covered(cid, checks, grafana_ok, now)
        if st["covered"]:
            continue
        if not st.get("sent"):
            new.append(cid)
        elif now - st.get("last_sent", 0) >= REMIND:
            remind.append(cid)
    return new, remind, cleared


def compose(new, remind, cleared, results, state):
    if not (new or remind or cleared):
        return None
    counts = [f"{len(x)} {w}" for x, w in ((new, "new"), (remind, "still failing"), (cleared, "cleared")) if x]
    lines = ["monero-node watchdog (GitHub): " + ", ".join(counts)]
    for title, ids in (("ALERT", new), ("STILL FAILING", remind)):
        for cid in ids:
            st = state["checks"][cid]
            what, who, step = describe(cid, st.get("detail", ""), results)
            lines += ["", f"{title} {kind_of(cid)[0].upper()}: {what}", f"Who is affected: {who}",
                      f"First step: {step}", f"Since {hhmm(st['since'])} UTC."]
    for cid, st in cleared:
        box, kind = kind_of(cid)
        text = CLEARED_TEXT[kind].format(port=cid.rsplit("-", 1)[1], b=box.upper())
        lines += ["", f"CLEARED {box.upper()}: {text} It failed from {hhmm(st['since'])} UTC."]
    lines += ["", "The watchdog checks both boxes from outside every 10 minutes. It sends only "
              "what the boxes cannot send."]
    return "\n".join(lines)


def send(text, token, chat):
    url = f"{TELEGRAM_API.rstrip('/')}/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat, "text": text, "disable_web_page_preview": "true"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as r:
            if json.loads(r.read()).get("ok"):
                return True
            log("::error::Telegram did not accept the message")
    except urllib.error.HTTPError as e:
        # Never print the URL or the error text: the URL holds the bot token
        log(f"::error::Telegram refused the message (HTTP {e.code})")
    except (OSError, ValueError) as e:
        log(f"::error::Telegram send failed ({type(e).__name__})")
    return False


def summary(results, state, text, outcome):
    """Writes the checks and the message to the job summary of the run. It
    holds the same as the logs: check ids, status and short error names."""
    lines = ["### Watchdog", "", outcome, "", "| Check | Status | Detail |", "|---|---|---|"]
    for cid in sorted(results):
        status, detail, _ = results[cid]
        if status == "fail" and state["checks"].get(cid, {}).get("covered"):
            status = "fail, a box sends the alert"
        lines.append(f"| {cid} | {status} | {detail} |")
    if text:
        lines += ["", "```text", text, "```"]
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        print("\n".join(lines))
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            s = json.load(f)
        if s.get("version") == STATE_VERSION:
            return s
    except (OSError, ValueError):
        pass
    return {"version": STATE_VERSION, "checks": {}, "heights": {}}


def save_state(path, state):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description="External watchdog for both boxes.")
    ap.add_argument("--state", required=True, help="state file: read at the start, written at the end")
    ap.add_argument("--tor-container", default="", help="Docker container of the Tor client on the runner")
    ap.add_argument("--socks", default="127.0.0.1:9050", help="SOCKS address of that Tor client; empty for none")
    ap.add_argument("--dry-run", action="store_true", help="print the message; send nothing, write no state")
    args = ap.parse_args()
    now = float(os.environ.get("NOW") or time.time())
    live = os.environ.get("WATCHDOG_LIVE") == "1"
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN", ""), os.environ.get("TELEGRAM_CHAT_ID", "")
    if live and not args.dry_run and not (token and chat):
        log("::error::Set the TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID repository secrets.")
        return 1
    boxes = load_targets()
    if not boxes:
        log("::error::No probe targets found")
        return 1
    state = load_state(args.state)

    # When the runner has no network, every check fails. Then no check
    # counts, and the state stays as it is.
    ok, detail, _, _ = retry(check_control, CONTROL_URL)
    if not ok:
        log(f"::warning::The runner cannot reach the control URL ({detail}). No check counts in this run.")
        return 0

    results = run_checks(boxes, args.socks or None, args.tor_container)
    if any(r[1] == NO_TOR for r in results.values()):
        log(f"::warning::{NO_TOR}. The onion checks do not count in this run.")
    height_checks(boxes, results, state, now)
    new, remind, cleared = decide(results, state, now)
    failing = sorted(c for c in state["checks"] if results.get(c, ("",))[0] == "fail")
    covered_ids = [c for c in failing if state["checks"][c].get("covered")]
    log(f"{len(failing)} failing, {len(covered_ids)} of them covered by the alerts of a box")
    log(f"to send: {len(new)} new, {len(remind)} reminders, {len(cleared)} cleared")
    text = compose(new, remind, cleared, results, state)
    if args.dry_run:
        if text:
            print("----- message\n" + text)
        return 0
    if not live:
        save_state(args.state, state)
        summary(results, state, text, "Telegram is off: the repository variable WATCHDOG_LIVE is not 1. "
                + ("A live run sends this message:" if text else "A live run sends nothing."))
        log("Telegram is off (WATCHDOG_LIVE is not 1). The result is in the job summary.")
        return 0
    if text and not send(text, token, chat):
        # Keep the cleared checks, so that the next run sends them again.
        # The new and the reminded checks get no send time.
        for cid, st in cleared:
            state["checks"][cid] = st
        save_state(args.state, state)
        summary(results, state, text, "The Telegram send failed. The next run tries again.")
        return 1
    for cid in new:
        state["checks"][cid]["sent"] = now
    for cid in new + remind:
        state["checks"][cid]["last_sent"] = now
    save_state(args.state, state)
    summary(results, state, text, "Sent to Telegram:" if text else "Nothing to send.")
    if text:
        log("sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
