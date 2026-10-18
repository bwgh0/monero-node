# Capacity

This page lists the limits of each box, the capacity alerts and their
runbooks, the capacity metrics and the weekly digest. The goal: know about a
limit before users meet it. [monitoring.md](monitoring.md) tells which box
sends which alert.

## Limits

Numbers from the capacity audit of October 2026, for one box.

| Limit | Value | Set where | What happens at the limit | Bites at (estimate) | Level at the audit |
|---|---|---|---|---|---|
| Sockets per public IP, restricted RPC | 10 (default 3) | `--rpc-max-connections-per-public-ip=10` | monerod accepts and closes the socket. wallet2 changes to plain HTTP and stays broken until the user reopens the wallet. | 10 open wallets behind one IP, or 4 iOS unlocks at the same time (each unlock adds 2 sockets); shared VPN, carrier NAT or Tor exit IPs | max 1 |
| Sockets in total, restricted RPC | 100 | default (`--rpc-max-connections`) | the same, for every new client | about 100 open wallets at one time. About 1,500 to 3,000 daily iOS users on the US box. 100 background-sync users fill it alone. | 1 to 2 |
| Sockets per private IP (all Tor users share the onion-proxy IP) | 50 | `--rpc-max-connections-per-private-ip=50` | every new Tor wallet fails | only through the count leak: the onion-proxy pool stays at 32 or less | 0 |
| onion-proxy pool to monerod (plain and TLS onion clients) | 32 requests at monerod at a time (`max_conns`) | onion-proxy.conf | nginx answers each request above 32 at once with a 502 ("no live upstreams"), and monerod never sees it | 32 requests that wait for monerod's 2 RPC threads at the same time: a monerod that stalls, or far more onion load than Tor can carry. 60 parallel Tor clients used 6 sockets in the lab. | 1 to 2 |
| onion-proxy reply store | 1 GiB tmpfs (`/var/cache/nginx`) | docker-compose.yml | nginx stops the reply in the middle ("No space left on device" in its log) | about 40 replies of 25 MB that Tor still sends at the same time | 0 |
| RPC worker threads | 2 per server | fixed in the monerod build (`daemon/rpc.h`) | requests queue, and latency rises for all users | about 10 wallets that catch up at the same time | 2.6% of one thread |
| Included traffic | 3 TiB outbound per month (cpx31 in ash, hcloud server describe). Inbound is free. | server plan | overage at $1.20 per TB (cost only) | about 3 times the egress of October 2026: about 5,000 more daily users, fewer with many restores | about 30% (about 1 TB per month) |
| Disk | 150 GB filesystem | server type (CPX31) | monerod stops when the disk is full | 80% about mid-December 2026; 85% about May 2027 | 78% |
| monerod CPU | 2 cores (cgroup) | compose `cpus: 2.0` | throttling, slow RPC | far | under 8% |
| monerod memory | 4 GiB (cgroup) | compose `mem_limit: 4g` | OOM kill and restart | far | 334 MB anonymous |
| monerod open files | 1024 soft | Docker default | accept fails | only after the socket caps go up | 111 |
| onion-proxy | 1 worker x 4096 connections, 16384 open files | onion-proxy.conf | nginx drops connections | about 1,300 open Tor connections (each uses 3 nginx connections) | about 2 |
| Request size, response soft limit | 1 MB, 25 MiB | monerod defaults | request refused, response cut | far | |

Assumptions behind the user counts:

- 2 sessions per daily user, about 2 minutes each.
- The wallet socket stays open 5 minutes after the session (10 minutes on the
  onion). iOS probe sockets add 0 to 10 socket-minutes per session.
- The busiest hour carries 2.5 times the average. The target is 80% of the
  cap at the busiest hour.
- One public IP per user. With node.monero.one on both boxes, the clearnet
  numbers double.
- About 0.4 GB of egress per daily user per month (the traffic row).

Above 120 sockets on one server, epee shortens the idle timeout for IPs with
several sockets: the base timeout shifted right by (sockets from that IP
minus 1), at most 8. The onion-proxy IP then gets 30 min / 256, about 7 s.
Tor wallets poll every 10 s, so at that load each poll needs a new connection.

## The per-IP count leak

monerod v0.18.4.5 counts the sockets of each IP, and some path skips the
decrement. Many short connections from one IP at the same time is the known
trigger. A monerod restart resets every count. A leaked count makes monerod
refuse an IP below the real number of sockets.

The IPs at risk: the onion-proxy IP (all Tor users), VPN exits, carrier NAT
and homes with several devices.

Canaries:

- Each box probes the RPC of the other box every minute from its public IP.
  Peer RPC Refused fires when only the other box fails these probes.
- The onion probes share the onion-proxy IP with all Tor users. Onion Down
  while the RPC passes points to the count of the onion-proxy IP.

### How a refusal shows

| Layer | Sign |
|---|---|
| monerod | No log line. The accept handler closes the socket. |
| Kernel, monerod namespace | `TCPAbortOnClose` rises when the client sent its ClientHello before the close. |
| Kernel, monerod namespace | Server-side TIME-WAIT sockets pile up for one IP. A downgraded wallet makes about 6 failing plain-HTTP connections per minute. |
| Wire | Plain HTTP (`POST /...`) arrives on 443 or 18089. |
| Client log | wallet2: "SSL handshake failed on an autodetect connection, reconnecting without SSL". The app shows no sync. |
| Onion (plain and TLS) | nginx in onion-proxy logs "peer closed connection in SSL handshake" and returns 502. |
| Probes | Peer RPC Refused, or Onion Down while the RPC passes. |

## Capacity alerts

The rules are in monitoring/grafana/provisioning/alerting/capacity-rules.yml.
Each box alerts about itself. All queries are instant, so a rule reads the
value of now.

| Title | Fires when | for | Severity |
|---|---|---|---|
| RPC Connections High / Critical | restricted RPC sockets above 50% / 80% of `--rpc-max-connections` | 10m / 5m | warning / critical |
| Onion RPC Connections High / Critical | onion-proxy sockets above 50% / 80% of the private-IP cap | 10m / 5m | warning / critical |
| Public IP At RPC Cap | a public IP holds as many sockets as the per-IP cap | 15m | warning |
| RPC Clients Reconnecting | a public IP has 4 or more sockets that monerod closed in the last minute | 10m | warning |
| RPC Busy High / Critical | the 2 restricted RPC threads are busy above 50% / 80% of the time | 15m / 10m | warning / critical |
| Monthly Traffic High | the month will use more than 80% of the included egress (from day 4) | 1h | warning |
| Included Traffic Used Up | the month used more than the included egress | 1h | warning |
| OOM Kill | the kernel killed a process for lack of memory | 0s | critical |
| Capacity Metrics Stale | the capacity file is older than 5 minutes | 5m | warning |
| Capacity Metrics Broken | a part of the capacity script failed | 15m | warning |
| Capacity Digest Missing | the weekly digest did not finish in 8 days | 1h | warning |
| Egress Rate High | the host sends more than 50 Mbit/s | 30m | warning |
| monerod CPU High | monerod uses more than 70% of its CPU limit | 30m | warning |
| monerod CPU Throttled | the cgroup throttles monerod in more than 10% of periods | 15m | warning |
| monerod Memory High | anonymous memory above 75% of the memory limit | 15m | warning |
| monerod File Descriptors High | open files above 70% of the soft limit | 10m | warning |
| monerod Threads High | threads above 80% of the pids limit | 10m | warning |
| RPC Sockets Stuck | more than 10 RPC sockets in CLOSE-WAIT | 30m | warning |
| Disk Fills Within 30 Days | at the 7-day trend, the disk passes 85% within 30 days | 1h | warning |
| Tor CPU High | Tor uses more than 0.7 core | 30m | warning |
| Onion Proxy Dropping Connections | nginx in onion-proxy accepted connections that it could not handle | 0s | warning |

The probe rule RPC Slow is in probe-rules.yml. Its runbook is below too.

## Runbooks

Run the commands on the box, in /opt/monero-node. To query Prometheus there:

```
P=$(docker inspect -f '{{.State.Pid}}' prometheus)
nsenter -t "$P" -n curl -s -G http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=<expr>'
```

To read the capacity file: `grep -E '^capacity_rpc' /var/lib/node-exporter/textfile/capacity.prom`.

### RPC Connections High, RPC Connections Critical

Open wallets fill the socket limit of the public RPC. At the limit, monerod
refuses every new wallet, and that wallet stays broken until it reopens.

1. Check the split: `capacity_rpc_connections` by source. Many public sockets
   means real growth. Many from one source means one client or the onion-proxy.
2. Compare the other box. When node.monero.one points to one box only, point
   it to both.
3. Raise the caps on both boxes: `--rpc-max-connections=500`,
   `--rpc-max-connections-per-public-ip=16`,
   `--rpc-max-connections-per-private-ip=200` and `ulimits: nofile` 65536 in
   docker-compose.yml. The deploy restarts monerod. Above 120 sockets, epee
   shortens the idle timeouts (see Limits), so watch Onion Down after the change.
4. For lasting growth, add a node and put it in DNS.

### Onion RPC Connections High, Onion RPC Connections Critical

All onion requests, plain and TLS, go through one pool of sockets in
onion-proxy (onion-proxy.conf). The pool holds at most 32 sockets
(`max_conns`), 18 under the private-IP cap of 50. High fires above 25
sockets, Critical at 30. With a full pool, nginx answers each new request at
once with a 502, so some onion wallets fail to sync. A pool this full means
that requests wait for monerod: its 2 RPC threads are busy, or it stalls.

1. Check RPC Busy, monerod CPU and `docker logs --tail 50 monerod`. A slow
   monerod fills the pool for all users, clearnet too.
2. Compare `capacity_onion_socket_clients` and `tor_hs_rdv_established_count`
   with the monerod count, to see how much onion load there is.
3. To raise the pool, raise `max_conns` and `keepalive` in onion-proxy.conf
   together, and raise `--rpc-max-connections-per-private-ip` so that the pool
   stays well under it. Keep that cap at or below `--rpc-max-connections`, or
   monerod stops at start. Move the alert thresholds in capacity-rules.yml with
   the pool.
4. When Onion Down fires while the counts look low, the leak holds the
   onion-proxy IP. Restart monerod at a quiet hour: `docker compose restart monerod`.

### Public IP At RPC Cap

One public IP holds as many sockets as the cap for 15 minutes. monerod refuses
its next socket, and that wallet changes to plain HTTP.

1. Read `capacity_rpc_public_max_per_ip` and its history in Grafana. Short
   peaks are iOS unlocks. A flat line at the cap means a shared IP (VPN,
   carrier NAT) or one busy client.
2. Raise `--rpc-max-connections-per-public-ip` in docker-compose.yml.
3. When Peer RPC Refused also fires, the leak may hold that IP. Restart
   monerod at a quiet hour.

### RPC Clients Reconnecting

A public IP has 4 or more sockets that monerod closed in the last minute, for
10 minutes. This is the pattern of a downgraded wallet (plain HTTP to the TLS
port every 10 s) or of a refused client that tries again.

1. Check Public IP At RPC Cap, RPC Connections and Peer RPC Refused. A refusal
   comes first.
2. Fix the cause (the cap or the leak). The wallet recovers when the user
   reopens it or pulls to refresh. Android users move to another node.
3. Write down the time since the last monerod restart. It is a data point for
   the leak rate.

The probes of the other box make about 2 TIME-WAIT sockets per minute, below
the level of 4.

### RPC Busy High, RPC Busy Critical

The 2 RPC threads are busy for more than half (or 80%) of the time. Requests
queue, and every wallet slows. The rule leaves out the methods of the exporter.

1. Find the method: `topk(5, sum by (method)(rate(monero_rpc_seconds_total[5m])))`.
   `get_blocks` means restores or catch-up.
2. Check RPC Slow and the host CPU. Short restore waves pass on their own.
3. For lasting load, spread the users to the other box or add a node. The
   thread count is fixed in the monerod build.

### RPC Slow

The RPC probes of this box take more than 2 s on average over 5 minutes, for
10 minutes. The base is about 10 to 50 ms.

1. Check RPC Busy, monerod CPU, throttling and disk IO.
2. When the probes of the other box are fast, check the network of this box.

### Monthly Traffic High, Included Traffic Used Up

The month will use (or used) more than 80% (or 100%) of the included egress.
Hetzner bills outgoing traffic only. Overage costs $1.20 per TB in US
locations (hcloud server describe).

1. Split the egress: P2P (`monero_net_tx_bytes`), clearnet RPC and Tor
   (`capacity_netns_network_bytes_total`).
2. For P2P cost, lower `--limit-rate-up`. For RPC growth, accept the cost or
   move the box to an EU location (20 TB included).

The included traffic is 3 TiB (3298534883328 bytes) unless you set it. That
is the amount of a cpx31 in ash (hcloud server describe), the plan of both
boxes. To change it, add `INCLUDED_TRAFFIC_BYTES=<bytes>` (digits only) to
the .env of the box. scripts/capacity-metrics.sh reads only this key of
.env, at its next run.

### OOM Kill

The kernel killed a process for lack of memory. `node_vmstat_oom_kill` is the
host-wide count. Docker restarts the container, so Container Crashed fires
too. A monerod restart resets the RPC counts and drops all wallets for 1 to 2
minutes.

1. Find the process: `journalctl -k --since -1h | grep -i 'killed process'`.
   Then check `capacity_cgroup_memory_anon_bytes` before the kill and
   `docker logs --tail 50 <container>`.
2. Raise `mem_limit` when the use is real growth. The host has about 7.75 GB.

### Capacity Metrics Stale, Capacity Metrics Broken

The capacity file is older than 5 minutes, or one part of the script failed.
The capacity alerts are blind.

1. Run `bash /opt/monero-node/scripts/capacity-metrics.sh` by hand and read the error.
2. Check /etc/cron.d/monero-node-capacity, the textfile directory and the
   `part` label of the failed part.

### Capacity Digest Missing

The weekly digest did not finish in 8 days.

1. Run `python3 /opt/monero-node/scripts/capacity-report.py --dry-run`.
2. Check the cron entry and the Telegram keys in .env. Check that the keys
   exist, and keep their values out of logs.

### Egress Rate High

The host sends more than 50 Mbit/s for 30 minutes (a pace of 16 TB per month).

1. Split by container (`capacity_netns_network_bytes_total`). P2P peaks come
   from peers that sync from this node. RPC peaks come from restores.
2. For abuse from one client, check Public IP At RPC Cap. For P2P, think about
   `--limit-rate-up`.

### monerod CPU High, monerod CPU Throttled

monerod uses more than 70% of its 2-core limit, or the cgroup throttles it in
more than 10% of periods.

1. Check RPC Busy and the P2P peers. A resync or many syncing peers can cause it.
2. Raise `cpus` in docker-compose.yml (the host has 4 vCPU), or add a node.

### monerod Memory High

Anonymous memory is above 75% of 4 GiB. The LMDB page cache is file memory
and frees itself, so the rule leaves it out.

1. Watch the trend for an hour. Raise `mem_limit` before an OOM kill.

### monerod File Descriptors High, monerod Threads High

monerod uses more than 70% of its soft limit of open files, or more than 80%
of its pids limit.

1. Add `ulimits: nofile` or raise `pids_limit` in docker-compose.yml. Both need
   a monerod restart.

### RPC Sockets Stuck

More than 10 RPC sockets wait in CLOSE-WAIT for 30 minutes. The client closed,
and monerod still holds the socket. This can be the leak in a form that we can see.

1. Write down the count and the time since the last restart. Restart monerod
   at a quiet hour when the count grows.
2. Add the data to the upstream bug report.

### Disk Fills Within 30 Days

At the 7-day trend, the disk passes 85% within 30 days.

1. Check `docker system df` and `du -sh /var/lib/docker/volumes/*`.
2. Plan the disk: a larger server type, or a Hetzner volume for the chain.
   FCMP++ (about March 2027) will grow the chain faster.

### Tor CPU High

Tor uses more than 0.7 core for 30 minutes. Tor does most work on one core.

1. Check `tor_hs_intro_num_total` and `tor_hs_intro_rejected_intro_req_count`
   for an introduction flood.
2. For a flood, think about `HiddenServicePoWDefensesEnabled 1`.

### Onion Proxy Dropping Connections

nginx in onion-proxy accepted connections that it could not handle:
`worker_connections` is used up.

1. Raise `worker_connections` and `worker_rlimit_nofile` in onion-proxy.conf.
   Each Tor connection uses 3 nginx connections, and each reply in the
   reply store uses 1 more file.

## Capacity metrics

`scripts/capacity-metrics.sh` writes /var/lib/node-exporter/textfile/capacity.prom
every minute (cron: scripts/capacity.cron, installed as
/etc/cron.d/monero-node-capacity). node-exporter reads the file. The metrics
hold counts only: client IPs stay inside the script.

| Metric | Labels | Meaning |
|---|---|---|
| `capacity_rpc_connections` | server (restricted, unrestricted), source (public, onion, gateway, nginx, blackbox, rpc_proxy, other_private) | established RPC sockets |
| `capacity_rpc_limit` | kind (total, public_ip, private_ip) | the caps from the monerod command line |
| `capacity_rpc_public_ips`, `capacity_rpc_public_max_per_ip`, `capacity_rpc_public_ips_at_cap` | server | public IPs, the busiest IP, the IPs at the cap |
| `capacity_rpc_churn_ips` | server | public IPs with 4 or more TIME-WAIT sockets: monerod closed them in the last minute |
| `capacity_rpc_timewait_max_per_ip` | server, class | the most TIME-WAIT sockets of one IP |
| `capacity_rpc_sockets` | server, state | RPC sockets by TCP state |
| `capacity_p2p_connections` | direction | P2P peers in and out |
| `capacity_onion_socket_clients` | | Tor clients of the onion-proxy |
| `capacity_netns_network_bytes_total` | container, network, direction | traffic of a container per network |
| `capacity_netns_tcp_curr_estab`, `capacity_netns_tcp_total`, `capacity_netns_tcpext_total` | container, counter | kernel TCP counters of a container |
| `capacity_host_network_bytes_total` | device, direction | traffic of the host |
| `capacity_host_tcpext_total` | counter | kernel TCP counters of the host |
| `capacity_host_conntrack_entries`, `capacity_host_conntrack_limit` | | connection tracking |
| `capacity_new_connections_total` | port | new connections per public port |
| `capacity_host_tx_month_bytes`, `capacity_traffic_included_bytes` | | egress this calendar month (UTC), and the included traffic |
| `capacity_cgroup_cpu_usage_seconds_total`, `capacity_cgroup_cpu_limit_cores`, `capacity_cgroup_cpu_periods_total`, `capacity_cgroup_cpu_throttled_periods_total` | container | CPU use, limit and throttling |
| `capacity_cgroup_memory_bytes`, `capacity_cgroup_memory_anon_bytes`, `capacity_cgroup_memory_limit_bytes`, `capacity_cgroup_oom_kills_total` | container | memory use, limit and OOM kills |
| `capacity_cgroup_pids`, `capacity_cgroup_pids_limit` | container | threads and the pids limit |
| `capacity_process_open_fds`, `capacity_process_fd_soft_limit`, `capacity_process_threads` | container | open files and threads of the main process |
| `capacity_container_start_time_seconds` | container | start time of the container |
| `capacity_onion_proxy_connections` | state | open connections of nginx in onion-proxy (stub_status) |
| `capacity_onion_proxy_accepts_total`, `capacity_onion_proxy_handled_total`, `capacity_onion_proxy_requests_total` | | accepted and handled connections, and requests (stub_status) |
| `capacity_metrics_parse_ok` | part | 1 when a part of the script passed, 0 when it failed |
| `capacity_metrics_last_run_timestamp_seconds` | | the time of the last run |
| `capacity_report_last_success_timestamp_seconds` | | the time of the last digest that Telegram accepted (capacity-report.prom) |

The script also copies the `tor_hs_*` metrics from the MetricsPort of Tor
(loopback in the tor container) into the file, with the onion name removed.

## Weekly digest

`scripts/capacity-report.py` runs on each box every Monday at 13:00 UTC and
sends one Telegram message about that box. monitoring.md tells why it runs on
the box. `--dry-run` prints the message and sends nothing.

Example (the numbers are examples):

```
monero-node weekly: US (2026-10-13 to 2026-10-20)

RPC sockets: peak 15 of 100 (15%). Clearnet wallets: peak 12, avg 1.8, 43 socket-hours/day
Tor sockets: peak 2 of 50 (4%). Tor clients peak 3. Tor errors 0, intro rejects 0
Busiest public IP: 2 of 10 (20%). IP-minutes at cap: 0. Reconnecting IP-minutes: 0
RPC threads: peak 22% (5 min), avg 1.1%. RPC probe p95 from this box: US 12 ms, EU 45 ms
...
Weeks to warn level (80% of the limit): sockets 46, Tor flat, per-IP flat, RPC threads flat, traffic flat
Change vs last week: socket peak +2, egress +4%

Heartbeat: the US box sends this digest every Monday at 13:00 UTC ...
```

How to read it:

- The socket peak and the socket-hours rise with the users. These two lines
  tell how close the box is to the limit.
- IP-minutes at the cap and reconnecting IP-minutes above 0 mean that users
  meet the per-IP cap. Raise it.
- Most new connections on 443 are Route 53 health checks (about 46,000 per
  day). The rest is wallet sessions and iOS probes.
- "Weeks to warn level" fits a line to the last 3 to 8 weeks and tells when a
  value reaches 80% of its limit. "now" means it is there. "flat" means no
  growth, or more than 2 years away. A new box shows "needs 3 weeks of data".
- When the digest does not arrive on Monday, the alert path of that box is
  broken. Check Grafana and the cron on the box.

Each run adds one row to /var/lib/monero-node-capacity/history.csv (the last
104 weeks). A second run on the same day replaces the row of that day.
