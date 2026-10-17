# Monitoring

This page tells who watches the boxes, which box sends which alert, what the
messages look like, and how the GitHub watchdog and Dependabot work.
[capacity.md](capacity.md) has the limits, the capacity alerts and their runbooks.

## Who watches what

| Watcher | Runs on | Watches | Sends |
|---|---|---|---|
| Prometheus and Grafana | each box | its own services, and the RPC, onion, cert and Grafana of the other box | Telegram, through the contact point of the box |
| Weekly digest | each box (cron, Monday 13:00 UTC) | the capacity numbers of the box | one Telegram message per box per week |
| Watchdog | GitHub Actions, every 10 minutes | both boxes from outside | Telegram, only for what the boxes cannot send |

Each box probes both boxes (monitoring/prometheus.yml). Every probe series has
a `node` label (us, eu) and a `domain` label. `deploy.sh render` writes the
domain of the box into the rule files, so each box knows which probes are its own.

## Routing: one message per incident

Each box alerts only about its own services. Two rules look at the other box:

| Rule | Sent by | Fires when |
|---|---|---|
| Grafana Unreachable | the other box | the Grafana of a box did not answer for 10 minutes. This is the dead-man check: a box with no Grafana sends no alerts. The message tells if the RPC and the onion of that box answer. |
| Peer RPC Refused | the other box | the RPC of a box refused every probe from the other box for 15 minutes, while the Grafana and the onion of that box answer. This is the canary for the per-IP cap (see Public IP At RPC Cap in capacity.md). |

All other rules are about the box that sends them:

| File | Rules |
|---|---|
| rules.yml | Node Down, Node Falling Behind, Node Height Stale, Node Not Synchronized, P2P Peers Low, Monero Exporter Blind, System Exporter Down, Scrape Target Down, CPU Usage High, RAM Usage High, Disk Usage Warning, Disk Usage Critical, Disk Fills Within 14 Days, Disk Almost Full, Prometheus Unreachable |
| probe-rules.yml | RPC Endpoint Down, RPC Slow, TLS Cert Expiring, Onion Down, Onion TLS Down (plus the two rules above) |
| container-rules.yml | Container Down, Container Crashed, Container Unhealthy, Container Metrics Stale |
| capacity-rules.yml | the capacity rules (see capacity.md) |

When both boxes are down at the same time, neither box can send. Then the
watchdog sends the alert.

### Quiet rules

Some rules stay quiet while a rule with the same cause fires:

- Onion Down, Monero Exporter Blind and Container Unhealthy (monerod) stay
  quiet while all RPC probes of the box fail. RPC Endpoint Down covers the
  monerod outage.
- Monero Exporter Blind stays quiet while monero-exporter is down. Node Down
  covers it.
- Onion TLS Down stays quiet while the plain onion probe fails. Onion Down covers it.
- Peer RPC Refused stays quiet while the Grafana or the onion of the other box
  fails. Grafana Unreachable or the alerts of that box cover it.
- Container Metrics Stale and Capacity Metrics Stale stay quiet while
  node-exporter is down. System Exporter Down covers it.

### Duplicates that can still occur

These cases send 2 messages for one cause. They are rare, and each message is true:

- A wrong or expired cert: the box sends RPC Endpoint Down, and the other box
  sends Peer RPC Refused.
- nginx down on a box: Grafana sits behind nginx on port 80, so the other box
  sends Grafana Unreachable while the box itself still alerts. After 30
  minutes the watchdog also sends.
- A broken network path between the boxes: both boxes can send Grafana
  Unreachable or Peer RPC Refused about each other.

## Message format

Each Telegram message has one block per alert (alerting/templates.yml):

```
ALERT US: Onion Down
What broke: The onion of this box fails over plain HTTP
Who is affected: Onion users. The apps that use this onion cannot sync.
First step: On the US box run docker compose ps tor onion-proxy monerod and docker logs --tail 50 tor.
Details: ...
Since 2026-10-17 05:19 UTC. Sent by the US box.
```

- ALERT is a critical rule. WARNING is a warning rule.
- The box after ALERT is the box that the alert is about. "Sent by" names the
  box that sent it.
- When the alert clears, a CLEARED block follows, with the time span.
- Grafana groups the alerts by box (alerting/policies.yml), so one message
  holds the alerts of one incident on a box. The two rules about the other
  box (Grafana Unreachable, Peer RPC Refused) come in a message of their own.
- Grafana waits 90 seconds before the first message of a group. An alert that
  starts or clears later comes in an update, at most every 5 minutes. An
  update lists again all alerts that still fire, and each cleared alert once.
  A message repeats every 4 hours while an alert fires.
- A message shows at most 3 firing and 3 cleared alerts as blocks. The next 8
  of each come as one line each (`ALERT US: Node Down`), then "And N more."
  A link to the alert list in Grafana follows the lines of firing alerts. So
  a message stays under the Telegram limit of 4096 characters.
- A capacity rule with a High and a Critical level shows 2 blocks when the
  value passes both levels. The Critical block is the escalation.

### Blind rules

A rule whose query fails is blind. Every rule sets `execErrState: KeepLast`,
so while its query fails, the rule keeps its last state: a firing alert stays
firing, no alert clears, and a new problem gives no alert. A pending alert
still fires when its `for` time ends. A Prometheus restart, or an outage of up
to 5 minutes, thus sends no false CLEARED (for example "CLEARED US: RPC
Endpoint Down" while the RPC is still down). ci/smoke.sh checks the error
states. The known limits below tell what a longer outage does.

Prometheus Unreachable (rules.yml) is the one rule that alerts when the queries
fail. Its query `vector(1)` returns data whenever Prometheus answers. When the
query fails or returns no data for 3 minutes, the box sends:

```
WARNING US: Prometheus Unreachable
What broke: Grafana on this box cannot query Prometheus. The other alerts on this box keep their last state until Prometheus recovers.
Who is affected: Monitoring only. Until Prometheus recovers, no alert of this box clears, and a new problem gives no alert.
First step: Run docker compose ps prometheus and docker logs --tail 50 prometheus.
Details: ...
Since 2026-10-17 05:19 UTC. Sent by the US box.
```

- A Prometheus outage of less than 3 minutes sends no message.
- The alert is in the message group of the box. When this group sent a
  message before, for example about an incident that still runs, the alert
  comes in the next update, up to 5 minutes later. The update lists again
  the alerts that still fire, with the time when they started. When it is
  not one of the first 3 alerts, its line also shows the "What broke" text.
- When Prometheus answers again, a CLEARED block follows in the next update.

Some rules in rules.yml keep the default noDataState NoData. When the query of
such a rule returns no data, Grafana sends a DatasourceNoData alert. It shows as
"<rule title> (no data)". These alerts wait 8 minutes before the first message,
because Grafana keeps them active until 4 minutes after the last evaluation
with no data. So a gap in the data of less than about 4 minutes sends no
message. When 3 or more rules have no data at the same time, one message lists
them (at most 40 rule titles):

```
WARNING US: rules are blind
What broke: The queries of 4 rules return no data:
CPU Usage High
...
Who is affected: Monitoring only
First step: Look for the metrics of these rules in Grafana Explore.
```

Known limits:

- While Prometheus is down, a new problem gives no alert, and no alert
  clears. Prometheus Unreachable tells you about this state.
- When the query of one rule fails and the other queries work, no alert
  comes. The rule keeps its last state, and the Grafana alert list shows the
  error on the rule.
- KeepLast does not keep a no-data state: when its query fails, the rule goes
  to Normal. When Prometheus is down for more than about 4 minutes, a
  DatasourceNoData alert thus clears. When the data is still missing after
  Prometheus recovers, the alert comes again within about 8 minutes.
- After a Prometheus outage of more than 5 minutes, the first evaluation of a
  rule can run before the first scrape. A rule with an instant query and
  noDataState OK then gets no data, and its alert clears while the problem
  still runs. The alert comes again after the `for` time of the rule. This
  false CLEARED usually comes in the same update as the CLEARED of
  Prometheus Unreachable. Container Unhealthy, RPC Slow and most capacity
  rules use instant queries. A rule with a range query of 5 or 10 minutes
  still gets data after an outage of up to about 10 or 15 minutes.

## The watchdog

`.github/workflows/watchdog.yml` runs `scripts/watchdog.py` every 10 minutes
(at 3, 13, 23 and so on past the hour, away from the busy start of the hour).

### Checks

For each box, from the GitHub runner:

| Check id | Passes when |
|---|---|
| `<box>-rpc-443`, `<box>-rpc-18089` | get_info over TLS gives HTTP 200 and status OK |
| `<box>-height` | monerod is synchronized, is not busy syncing, is at most 10 blocks behind the other box, and its height changed in the last 60 minutes |
| `<box>-grafana` | `/grafana/api/health` gives database ok |
| `<box>-onion`, `<box>-onion-tls` | get_height over Tor gives status OK, over plain HTTP and over TLS |

The targets come from monitoring/prometheus.yml, so the watchdog checks the
same URLs as the probes of the boxes. A check fails only when every try fails
for 2 minutes (a new try every 15 seconds).

Two control checks protect against false alerts:

- When the runner cannot reach api.github.com, no check counts in that run.
- Tor runs on the runner in the tor-client image of docker-compose.yml. When
  Tor does not bootstrap in 150 seconds, the onion checks do not count in that run.

### When it sends

Telegram is on only when the repository variable `WATCHDOG_LIVE` is `1`.
Without it, each run writes the checks and the message to the job summary,
sends nothing and keeps its state, with no failure marked as sent.

The watchdog sends only what the boxes cannot send:

- A failed check of a box whose Grafana answers: the box sends the alert, so
  the watchdog stays quiet.
- A box whose Grafana does not answer, while the Grafana of the other box
  answers: the other box sends Grafana Unreachable. The watchdog waits 30
  minutes, then sends the Grafana check and every failed check of that box.
- Both Grafanas do not answer: the watchdog sends at once.

One message per run holds all new failures (ALERT), the reminders every 4
hours (STILL FAILING) and the recoveries (CLEARED). CLEARED goes out only for
a failure that the watchdog sent. The message is plain text and starts with
"monero-node watchdog (GitHub)".

When the Telegram send fails, the run fails (red). GitHub then sends an email
about the failed run, and the next run sends the message again. With
`WATCHDOG_LIVE` at `1`, a run also fails when the TELEGRAM_BOT_TOKEN or
TELEGRAM_CHAT_ID secret is missing.

### State

Each run keeps its state (what fails since when, what went out, the last
heights) in the artifact `watchdog-state`, kept for 3 days. The next run reads
the newest one. When no artifact exists, the watchdog starts again with an
empty state.

### Public logs

The repo is public, so the run logs are public. The watchdog prints only the
check ids, the status and short error names (timeout, HTTP 503). It prints no
IPs, no URLs, no onion names, no tokens and no chat ID.

### Keepalive

GitHub turns off the schedules of a public repo after 60 days with no commit.
The keepalive job of the workflow runs every Monday at 07:41 UTC and turns the
workflow on again through the API, which starts the 60 days again. More ways
back, when the schedule stops anyway:

- Any push to the repo starts the 60 days again.
- GitHub sends an email before it turns off a schedule.
- `gh workflow enable watchdog.yml` turns it on again.

### Run it by hand

- On GitHub: `gh workflow run watchdog.yml`. This also runs the keepalive.
- Locally: `python3 scripts/watchdog.py --state /tmp/watchdog.json --dry-run`
  prints the message and sends nothing. The onion checks need a Tor SOCKS
  proxy on 127.0.0.1:9050, else they fail.

## Weekly digest

`scripts/capacity-report.py` runs from cron on each box, every Monday at 13:00
UTC. capacity.md tells how to read it. It runs on the box because:

- It reads the local Prometheus of the box.
- It uses the Telegram keys of the box .env. It needs no new secret and no SSH key.
- It works when GitHub is down.

The digest is also a heartbeat. When it does not arrive on Monday, the alert
path of that box is broken: check Grafana and the cron on the box. The rule
Capacity Digest Missing fires when the digest did not finish in 8 days.

## Dependabot

`.github/dependabot.yml` opens update PRs every Monday for the images in
docker-compose.yml and for the GitHub Actions. Nothing merges on its own. CI
runs on each PR, and a merge to main deploys to both boxes.

- The minor and patch updates of the monitoring images (prometheus, grafana,
  blackbox-exporter, node-exporter, monero-exporter) come in one PR.
- Each other image comes in its own PR. monerod is never in a group.
- Only a monerod bump skips the automatic rollback of the deploy (deploy.sh
  exit 5), because the bitmonero volume holds the chain. A person must check a
  monerod PR. A rollback after a bump of grafana, prometheus or certbot is safe.
- The deploy refuses a monerod image change that ships with a change to
  another service. So merge a monerod PR alone, and wait for its deploy to
  finish before you merge the next PR.
- The monerod bump to v0.18.5.x is a separate task. The owner decides it.
- Dependabot updates an image line that has a version tag. node-exporter and
  monero-exporter have a digest and no tag, so check them by hand.

## Prometheus retention

Prometheus keeps 180 days of data, at most 2 GB (docker-compose.yml). The
capacity trends and the disk forecast need the long history.
