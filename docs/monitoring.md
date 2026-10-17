# Monitoring

This page tells who watches the boxes, which box sends which alert, what the
messages look like, and how the GitHub watchdog, its clock and Dependabot work.
[capacity.md](capacity.md) has the limits, the capacity alerts and their runbooks.

## Who watches what

| Watcher | Runs on | Watches | Sends |
|---|---|---|---|
| Prometheus and Grafana | each box | its own services, the RPC, onion, cert and Grafana of the other box, and the watchdog runs | Telegram, through the contact point of the box |
| Weekly digest | each box (cron, Monday 13:00 UTC) | the capacity numbers of the box | one Telegram message per box per week |
| Watchdog | GitHub Actions, every 10 minutes, started by an AWS EventBridge rule | both boxes from outside | Telegram, only for what the boxes cannot send |

Each box probes both boxes (monitoring/prometheus.yml). Every probe series has
a `node` label (us, eu) and a `domain` label. `deploy.sh render` writes the
domain of the box into the rule files, so each box knows which probes are its own.

## Routing: one message per incident

Each box alerts only about its own services. Two rules look at the other box,
and one rule looks at the watchdog:

| Rule | Sent by | Fires when |
|---|---|---|
| Grafana Unreachable | the other box | the Grafana of a box did not answer for 10 minutes. This is the dead-man check: a box with no Grafana sends no alerts. The message tells if the RPC and the onion of that box answer. |
| Peer RPC Refused | the other box | the RPC of a box refused every probe from the other box for 15 minutes, while the Grafana and the onion of that box answer. This is the canary for the per-IP cap (see Public IP At RPC Cap in capacity.md). |
| Watchdog Silent | the US box, and the EU box only while the Grafana of the US box fails | no watchdog run passed for 40 minutes. See [Watchdog Silent](#watchdog-silent). |

All other rules are about the box that sends them:

| File | Rules |
|---|---|
| rules.yml | Node Down, Node Falling Behind, Node Height Stale, Node Not Synchronized, P2P Peers Low, Monero Exporter Blind, System Exporter Down, Scrape Target Down, CPU Usage High, RAM Usage High, Disk Usage Warning, Disk Usage Critical, Disk Fills Within 14 Days, Disk Almost Full, Prometheus Unreachable |
| probe-rules.yml | RPC Endpoint Down, RPC Slow, TLS Cert Expiring, Onion Down, Onion TLS Down (plus the three rules above) |
| container-rules.yml | Container Down, Container Crashed, Container Unhealthy, Container Metrics Stale |
| capacity-rules.yml | the capacity rules (see capacity.md) |

When both boxes are down at the same time, neither box can send. Then the
watchdog sends the alert. When the watchdog stops, the boxes send Watchdog Silent.

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
- Container Metrics Stale, Capacity Metrics Stale and Watchdog Silent stay
  quiet while node-exporter is down. System Exporter Down covers it.

### Duplicates that can still occur

These cases send 2 messages for one cause. They are rare, and each message is true:

- A wrong or expired cert: the box sends RPC Endpoint Down, and the other box
  sends Peer RPC Refused.
- Watchdog Silent while the probe from EU to the US Grafana fails, but the US
  box can still send (for example a network fault between the boxes): both
  boxes send it.
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
  Prometheus Unreachable. The container rules, RPC Slow and most capacity
  rules use instant queries. A rule with a range query of 5 or 10 minutes
  still gets data after an outage of up to about 10 or 15 minutes.

## The watchdog

`.github/workflows/watchdog.yml` runs `scripts/watchdog.py`. An AWS
EventBridge rule starts it every 10 minutes with a workflow_dispatch event
(see [The clock](#the-clock)).

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

### The clock

GitHub started 0 scheduled runs of the watchdog in its first hours on main,
with 2 cron forms. Community reports since 2026-08-26 tell of scheduled runs
that GitHub drops or starts hours late
(github.com/orgs/community/discussions/207346). A workflow_dispatch event
starts a run at once. So the workflow has no schedule, and a clock outside
GitHub sends the event.

The clock is in the AWS account of Monero One, in us-east-1. All its parts
have the name `monero-node-watchdog-clock`:

| Part | What it does |
|---|---|
| EventBridge rule | `rate(10 minutes)` on the default event bus. Its target sends the body `{"ref":"main"}` with the headers `Accept: application/vnd.github+json` and `X-GitHub-Api-Version: 2022-11-28`. A failed call gets 2 more tries in 5 minutes. |
| API destination | POST to `https://api.github.com/repos/bwgh0/monero-node/actions/workflows/watchdog.yml/dispatches`. GitHub answers 204. |
| Connection | API key auth: the header `Authorization: Bearer <token>`. EventBridge keeps the token in Secrets Manager. |
| IAM role | events.amazonaws.com can assume it. Its only permission is `events:InvokeApiDestination` on that API destination. |

The token is a fine-grained GitHub token for bwgh0/monero-node only, with the
permission Actions: read and write. A copy is in the macOS Keychain of the
laptop (service `monero-node-watchdog-clock`, account `github`).
`scripts/watchdog-clock.sh` reads it into a mode-600 temp file for the AWS
CLI and deletes the file after the call. The script never prints the token.

GitHub turns off a workflow after 60 days with no commit only when the
workflow has a schedule. This workflow has none, so it needs no keepalive.

#### Set up the clock again

1. On GitHub, make a fine-grained token (Settings, Developer settings,
   Fine-grained tokens): resource owner bwgh0, only the repository
   monero-node, repository permission Actions: Read and write. Give it an
   expiry date, and put a reminder before that date in the calendar.
2. Put the token in the Keychain. The command asks for the token, so the
   token stays out of the command line and the shell history:
   `security add-generic-password -U -s monero-node-watchdog-clock -a github -w`
3. `scripts/watchdog-clock.sh --dry-run apply` prints the AWS calls and the
   JSON files they get. Read them.
4. `scripts/watchdog-clock.sh apply` creates the parts. You can run it again
   at any time: it creates what is missing and updates the rest. It keeps the
   token of a connection that exists.
5. After 10 to 20 minutes, `scripts/watchdog-clock.sh status` must show the
   connection AUTHORIZED, invocations with 0 failed invocations, and a new
   workflow_dispatch run that passed.

The script uses the AWS CLI profile `default` (WATCHDOG_CLOCK_PROFILE sets a
different one) and prints the account ID first. `scripts/watchdog-clock.sh
delete` removes all the parts. It asks first.

#### Rotate the token

1. Make a new token (step 1 above).
2. Run `security add-generic-password -U -s monero-node-watchdog-clock -a github -w`.
   With -U, it replaces the token in the Keychain.
3. `scripts/watchdog-clock.sh rotate-token` gives the connection the new token.
4. After 10 minutes, `scripts/watchdog-clock.sh status` must show a new
   workflow_dispatch run that passed. Then delete the old token on GitHub.

When the token expires or GitHub revokes it, GitHub answers 401. EventBridge
then sets the connection to DEAUTHORIZED and stops the dispatches. After 40
minutes, the boxes send Watchdog Silent. rotate-token makes the connection
AUTHORIZED again.

### Watchdog Silent

A watchdog that stops sends nothing. So the boxes watch the watchdog. Every
5 minutes, cron on each box runs `scripts/watchdog-metrics.py`
(`/etc/cron.d/monero-node-watchdog-metrics`). It asks the public GitHub API
for the newest run of watchdog.yml on main that passed, and writes the result
for the node-exporter textfile collector (`watchdog.prom`). It uses no token.
GitHub allows 60 such calls per hour from one IP, and the script makes 12.
The deploy runs the script once, so the metrics are there when Grafana loads
the rule.

| Metric | Value |
|---|---|
| `watchdog_last_success_timestamp_seconds` | The end of the newest good run. It only moves forward. When the API call fails, the last value stays. Before the first API call that works, it is the time of the first try. |
| `watchdog_github_api_ok` | 1 when the last API call worked, else 0 |
| `watchdog_github_api_last_ok_timestamp_seconds` | when an API call last worked |
| `watchdog_metrics_last_run_timestamp_seconds` | when the script last wrote the file |

Watchdog Silent (probe-rules.yml, critical) fires when no good run ended in
the last 40 minutes. With a run every 10 minutes, that is about 3 runs that
did not start or did not pass. When the file is missing, the rule counts from
the start of Prometheus, so a box with no file also alerts after 40 minutes.
The message tells the cause:

| Summary | Cause | First step |
|---|---|---|
| No watchdog run passed for N minutes | The clock stopped (for example an expired token or a DEAUTHORIZED connection), GitHub started no runs, or the runs fail. | `gh run list --workflow watchdog.yml`, and on the laptop `scripts/watchdog-clock.sh status` |
| The GitHub API call of this box fails | The box cannot see the runs, for example because of the rate limit of its IP. The watchdog can be fine. | On the box, `python3 /opt/monero-node/scripts/watchdog-metrics.py` prints the result of the call. |
| The watchdog metrics of this box are N minutes old, or This box has no watchdog metrics | The cron job does not run. | Check `/etc/cron.d/monero-node-watchdog-metrics`, then run the script by hand. |

One box sends it. The US box always sends it. The EU box sends it only when
its probe of the US Grafana failed for all of the last 10 minutes, so the
alert also comes when the US box is down. When the EU box has no probe data
of the US Grafana, it sends it too. Watchdog Silent stays quiet while
node-exporter is down (System Exporter Down covers it). When both boxes and
the watchdog stop at the same time, no message goes out.

### Run it by hand

- On GitHub: `gh workflow run watchdog.yml`.
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

- The minor and patch updates of the monitoring images (prometheus,
  blackbox-exporter, node-exporter, monero-exporter) come in one PR.
- Each other image comes in its own PR. monerod and grafana are never in a
  group.
- nginx stays on a stable line (an even minor, such as 1.30). Dependabot
  ignores the mainline minor 1.31. When Dependabot offers a new odd minor,
  add it to the ignore list in `.github/dependabot.yml`.
- Only a monerod bump skips the automatic rollback of the deploy (deploy.sh
  exit 5), because the bitmonero volume holds the chain. A person must check a
  monerod PR.
- A rollback after a certbot bump, or a minor or patch bump of prometheus, is
  safe: the old image reads the data. A grafana bump can migrate grafana-data
  one way. After a rollback, the old Grafana can then fail to start (deploy.sh
  exit 2), and the box sends alerts again only after a person restores
  grafana.db. The deploy copies grafana.db before the new image starts (see
  [Grafana database copies](#grafana-database-copies)). Deploy a grafana bump
  alone.
- Dependabot opens grafana PRs only for minor and patch versions. Plan a
  grafana major version by hand, and test the upgrade on a copy of the
  grafana.db of a box first.
- The deploy refuses a monerod image change that ships with a change to
  another service. So merge a monerod PR alone, and wait for its deploy to
  finish before you merge the next PR.
- The monerod bump to v0.18.5.x is a separate task. The owner decides it.
- Dependabot follows the version tag of an image. An image line with only a
  digest (monero-exporter) gets a PR to the digest of the latest tag, with no
  version number. Check such a PR by hand.

## Grafana database copies

Grafana keeps its SQLite database, grafana.db, in the grafana-data volume.
It holds the alert states, silences, annotations and the admin user. The
dashboards, alert rules, contact point and data source come from the repo.

When a deploy changes the grafana image, scripts/deploy.sh stops grafana and
copies grafana.db to `/root/grafana-db-<UTC time>.db` (mode 600) before the
new image starts. The deploy log names the file. The newest 5 copies stay.
When the copy fails, the deploy rolls back (exit 1), and the old Grafana
starts again. A copy holds the password hash of the admin user and the
contact point settings, so keep it on the box.

### Restore grafana.db after a rollback

A new Grafana can migrate grafana.db one way. After a rollback, the old
Grafana can then fail to start: the deploy exits with 2, and the check
"Grafana answers, database ok" fails. The box sends alerts again only when
Grafana runs. To put the copy back, do these steps on the box as root:

1. Find the copy from the failed deploy. The deploy log has the line
   `grafana.db backed up to /root/grafana-db-<UTC time>.db`. It is also the
   newest file in `ls -1 /root/grafana-db-*.db`.

   ```sh
   cd /opt/monero-node
   copy=/root/grafana-db-<UTC time>.db
   ```

2. Stop grafana.

   ```sh
   docker compose stop grafana
   ```

3. Put the copy in the volume. These commands use the image of the grafana
   container, which is the old image after the rollback. They keep the
   migrated database as grafana.db.migrated in the same volume.

   ```sh
   image=$(docker inspect -f '{{.Config.Image}}' grafana)
   volume=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}' grafana)
   docker run --rm --network none --user 0 --entrypoint sh \
       -v "$volume:/data" -v "$copy:/copy.db:ro" "$image" -c '
       cd /data && mv grafana.db grafana.db.migrated &&
       rm -f grafana.db-journal grafana.db-wal grafana.db-shm &&
       cp /copy.db grafana.db && chown 472:0 grafana.db && chmod 640 grafana.db'
   ```

4. Start grafana, and run the gate. The onion names are in
   .github/workflows/deploy.yml.

   ```sh
   docker compose up -d --no-deps --wait grafana
   scripts/deploy.sh gate --onion <name>.onion
   ```

5. When the gate passes, remove the migrated database.

   ```sh
   docker compose exec grafana rm /var/lib/grafana/grafana.db.migrated
   ```

Grafana loses the changes after the copy, for example a silence that a
person added during the failed deploy. It loads the dashboards and alert
rules from the repo again when it starts.

## Prometheus retention

Prometheus keeps 180 days of data, at most 2 GB (docker-compose.yml). The
capacity trends and the disk forecast need the long history.
