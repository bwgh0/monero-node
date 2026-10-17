#!/usr/bin/env python3
"""Writes the time of the last good watchdog run for the node-exporter
textfile collector. The rule Watchdog Silent (alerting/probe-rules.yml)
fires when that time is more than 40 minutes ago.

Cron runs it every 5 minutes (scripts/watchdog-metrics.cron, installed as
/etc/cron.d/monero-node-watchdog-metrics by setup.sh and the deploy). It
reads the public GitHub API with no token. GitHub allows 60 such requests
per hour from one IP. This script makes 12.

A good run is a run of .github/workflows/watchdog.yml on main that ended
with success. The metrics:
  watchdog_last_success_timestamp_seconds
      The end of the newest good run. It only moves forward. When the API
      call fails, the value from the last file stays. Before the first API
      call that works, it is the time of the first try, so the alert waits
      the full 40 minutes.
  watchdog_github_api_ok
      1 when the API call of this run worked, else 0.
  watchdog_github_api_last_ok_timestamp_seconds
      When an API call last worked.
  watchdog_metrics_last_run_timestamp_seconds
      When this file was written.

It prints one line with the result, for a run by hand.

Usage: watchdog-metrics.py
For tests: GITHUB_API, WATCHDOG_REPO, TEXTFILE_DIR and NOW.
"""

import datetime
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request

GITHUB_API = os.environ.get("GITHUB_API", "https://api.github.com").rstrip("/")
REPO = os.environ.get("WATCHDOG_REPO", "bwgh0/monero-node")
TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node-exporter/textfile")
OUT = os.path.join(TEXTFILE_DIR, "watchdog.prom")
TIMEOUT = 20
# The 10 newest good runs. The API docs give no sort order, so the script
# takes the newest of them.
URL = (f"{GITHUB_API}/repos/{REPO}/actions/workflows/watchdog.yml/runs"
       "?branch=main&status=success&exclude_pull_requests=true&per_page=10")


def previous():
    """The values of the last file, or an empty dict."""
    values = {}
    try:
        with open(OUT, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and not line.startswith("#"):
                    values[parts[0]] = float(parts[1])
    except (OSError, ValueError):
        pass
    return values


def newest_good_run():
    """Returns (end time of the newest good run or None, error text or "")."""
    req = urllib.request.Request(URL, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "monero-node-watchdog-metrics",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        why = f"HTTP {e.code}"
        if e.headers.get("x-ratelimit-remaining") == "0":
            reset = e.headers.get("x-ratelimit-reset", "")
            when = time.strftime("%H:%M UTC", time.gmtime(int(reset))) if reset.isdigit() else "later"
            why += f" (rate limit of this IP, free again at {when})"
        return None, why
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        return None, f"no answer ({reason if isinstance(reason, str) else type(reason).__name__})"
    except ValueError:
        return None, "the answer is not JSON"
    try:
        ends = [datetime.datetime.strptime(r["updated_at"], "%Y-%m-%dT%H:%M:%SZ")
                .replace(tzinfo=datetime.timezone.utc).timestamp()
                for r in data["workflow_runs"]
                if r.get("conclusion") == "success" and r.get("head_branch") == "main"]
    except (KeyError, TypeError, ValueError):
        return None, "the answer has an unknown format"
    return (max(ends) if ends else None), ""


def write(values):
    os.makedirs(TEXTFILE_DIR, exist_ok=True)
    helps = {
        "watchdog_last_success_timestamp_seconds":
            "End of the newest watchdog run on main that passed, from the GitHub API.",
        "watchdog_github_api_ok": "1 when the last GitHub API call of this box worked, else 0.",
        "watchdog_github_api_last_ok_timestamp_seconds": "When a GitHub API call of this box last worked.",
        "watchdog_metrics_last_run_timestamp_seconds": "When this file was written.",
    }
    fd, tmp = tempfile.mkstemp(prefix=".watchdog.prom.", dir=TEXTFILE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for name, text in helps.items():
                if name in values:
                    f.write(f"# HELP {name} {text}\n# TYPE {name} gauge\n{name} {values[name]:.0f}\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUT)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    now = float(os.environ.get("NOW") or time.time())
    old = previous()
    end, error = newest_good_run()
    known = [x for x in (old.get("watchdog_last_success_timestamp_seconds"), end) if x is not None]
    last = max(known) if known else now
    values = {
        "watchdog_last_success_timestamp_seconds": last,
        "watchdog_github_api_ok": 0 if error else 1,
        "watchdog_metrics_last_run_timestamp_seconds": now,
    }
    api_last_ok = now if not error else old.get("watchdog_github_api_last_ok_timestamp_seconds")
    if api_last_ok is not None:
        values["watchdog_github_api_last_ok_timestamp_seconds"] = api_last_ok
    write(values)
    ago = (now - last) / 60
    seen = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(last))
    if error:
        print(f"The GitHub API call failed: {error}. The last good run this box saw ended {seen} ({ago:.0f} min ago).")
        return 1
    print(f"The last good watchdog run ended {seen} ({ago:.0f} min ago).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
