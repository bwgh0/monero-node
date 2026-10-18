#!/usr/bin/env bash
# Writes capacity metrics for the node-exporter textfile collector: RPC
# sockets by source, per-IP peaks against the monerod caps, kernel TCP
# counters, cgroup use, host traffic and new connections per port.
# Cron runs it every minute as root (scripts/capacity.cron). Client IPs stay
# inside awk. The output has counts only. docs/capacity.md lists the metrics.
#
# Each part writes capacity_metrics_parse_ok{part="..."}: 1 when it passed,
# 0 when it failed. A failed part does not stop the other parts.
# For tests: TEXTFILE_DIR, CAPACITY_STATE_DIR, CGROUP_ROOT, LOCK_FILE and ENV_FILE.
set -uo pipefail

DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
STATE_DIR="${CAPACITY_STATE_DIR:-/var/lib/monero-node-capacity}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
ENV_FILE="${ENV_FILE:-/opt/monero-node/.env}"
# Outbound traffic included per month: 3 TiB for a cpx31 in ash (hcloud
# server describe). Inbound traffic is free. INCLUDED_TRAFFIC_BYTES=<bytes>
# in .env sets another amount. .env holds secrets, so only this key is read,
# never the whole file. The last line of the key wins. Quotes are dropped,
# and a value that is not all digits counts as unset.
included=$(sed -n 's/^INCLUDED_TRAFFIC_BYTES=//p' "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d "\"'\r")
[[ $included =~ ^[0-9]+$ ]] || included=3298534883328
INCLUDED_TRAFFIC_BYTES="${INCLUDED_TRAFFIC_BYTES:-$included}"
OUT="${DIR}/capacity.prom"
CONTAINERS=(monerod onion-proxy tor nginx monerod-rpc-proxy monero-exporter blackbox tor-client prometheus grafana)
# A hung dockerd must not hang the cron job: each docker call gets 10 s
dk() { timeout -k 5 10 docker "$@"; }

exec 9>"${LOCK_FILE:-/run/monero-node-capacity.lock}"
flock -n 9 || exit 0
mkdir -p "$DIR" "$STATE_DIR" || exit 1
TMP=$(mktemp "${DIR}/.capacity.prom.XXXXXX") || exit 1
RAW="$TMP.raw"
trap 'rm -f "$TMP" "$RAW"' EXIT

# run <part> <function>: runs the function with errexit in a subshell and
# records whether it passed. Its output goes to the raw file.
run() {
    local part=$1 rc
    shift
    (
        set -e
        "$@"
    ) >>"$RAW"
    rc=$?
    printf 'capacity_metrics_parse_ok{part="%s"} %d\n' "$part" "$((rc == 0 ? 1 : 0))" >>"$RAW"
}

declare -A PID CID STARTED
while read -r name pid id started; do
    name=${name#/}
    PID[$name]=$pid CID[$name]=$id STARTED[$name]=$started
done < <(dk inspect -f '{{.Name}} {{.State.Pid}} {{.Id}} {{.State.StartedAt}}' "${CONTAINERS[@]}" 2>/dev/null)

# Private IP -> container name, for the source label. The network gateways
# carry hairpin and docker-proxy traffic from the host.
names=""
while read -r name ips; do
    for ip in $ips; do names+=" $ip ${name#/}"; done
done < <(dk inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CONTAINERS[@]}" 2>/dev/null)
# shellcheck disable=SC2016 # a docker template, not shell
for net in $(dk inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' monerod 2>/dev/null); do
    for gw in $(dk network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$net" 2>/dev/null); do
        names+=" $gw gateway"
    done
done

m=${PID[monerod]:-0}
flag() { tr '\0' '\n' <"/proc/$m/cmdline" | sed -n "s/^--$1=//p" | tail -n 1; }

# --- RPC sockets of monerod, by server, source and state
rpc_part() {
    local lim_total lim_pub lim_priv
    ((m > 0))
    lim_total=$(flag rpc-max-connections)
    lim_pub=$(flag rpc-max-connections-per-public-ip)
    lim_priv=$(flag rpc-max-connections-per-private-ip)
    lim_total=${lim_total:-100} lim_pub=${lim_pub:-3} lim_priv=${lim_priv:-25}
    printf 'capacity_rpc_limit{kind="%s"} %s\n' total "$lim_total" public_ip "$lim_pub" private_ip "$lim_priv"
    nsenter -t "$m" -n ss -Htan | awk -v names="$names" -v cap="$lim_pub" '
        function port(a) { sub(/.*:/, "", a); return a }
        function host(a) { sub(/:[^:]*$/, "", a); gsub(/[][]/, "", a); sub(/^::ffff:/, "", a); sub(/%.*/, "", a); return a }
        function private(a) { return a ~ /^(10|127)\./ || a ~ /^192\.168\./ || a ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || a ~ /^(::1$|f[cd]|fe[89ab])/ }
        BEGIN {
            n = split(names, a, " "); for (i = 1; i < n; i += 2) nm[a[i]] = a[i + 1]
            srv["18089"] = "restricted"; srv["18081"] = "unrestricted"
            cls["onion-proxy"] = "onion"; cls["nginx"] = "nginx"; cls["blackbox"] = "blackbox"
            cls["monerod-rpc-proxy"] = "rpc_proxy"; cls["gateway"] = "gateway"
            ns = split("public onion gateway nginx blackbox rpc_proxy other_private", sources, " ")
            nt = split("estab syn-recv fin-wait-1 fin-wait-2 time-wait close-wait last-ack closing", states, " ")
        }
        {
            st = tolower($1); if (st == "listen") next
            lp = port($4); rp = port($5); ip = host($5)
            if (lp == "18080" && st == "estab") { p2p["in"]++; next }
            if (rp == "18080" && st == "estab") { p2p["out"]++; next }
            if (!(lp in srv)) next
            s = srv[lp]; pv = private(ip)
            sock[s, st]++
            if (st == "estab") {
                if (pv) { c = (nm[ip] in cls) ? cls[nm[ip]] : "other_private"; conn[s, c]++ }
                else { conn[s, "public"]++; per[s, ip]++ }
            }
            if (st == "time-wait") tw[s, (pv ? "private" : "public"), ip]++
        }
        END {
            for (lp in srv) {
                s = srv[lp]
                for (i = 1; i <= ns; i++) printf "capacity_rpc_connections{server=\"%s\",source=\"%s\"} %d\n", s, sources[i], conn[s, sources[i]]
                for (i = 1; i <= nt; i++) printf "capacity_rpc_sockets{server=\"%s\",state=\"%s\"} %d\n", s, states[i], sock[s, states[i]]
                ips[s] = mx[s] = atcap[s] = churn[s] = twpub[s] = twpriv[s] = 0
            }
            for (k in per) { split(k, z, SUBSEP); ips[z[1]]++; if (per[k] > mx[z[1]]) mx[z[1]] = per[k]; if (per[k] >= cap + 0) atcap[z[1]]++ }
            for (k in tw) {
                split(k, z, SUBSEP)
                if (z[2] == "public") { if (tw[k] > twpub[z[1]]) twpub[z[1]] = tw[k]; if (tw[k] >= 4) churn[z[1]]++ }
                else if (tw[k] > twpriv[z[1]]) twpriv[z[1]] = tw[k]
            }
            for (s in ips) {
                printf "capacity_rpc_public_ips{server=\"%s\"} %d\n", s, ips[s]
                printf "capacity_rpc_public_max_per_ip{server=\"%s\"} %d\n", s, mx[s]
                printf "capacity_rpc_public_ips_at_cap{server=\"%s\"} %d\n", s, atcap[s]
                printf "capacity_rpc_churn_ips{server=\"%s\"} %d\n", s, churn[s]
                printf "capacity_rpc_timewait_max_per_ip{server=\"%s\",class=\"public\"} %d\n", s, twpub[s]
                printf "capacity_rpc_timewait_max_per_ip{server=\"%s\",class=\"private\"} %d\n", s, twpriv[s]
            }
            printf "capacity_p2p_connections{direction=\"in\"} %d\ncapacity_p2p_connections{direction=\"out\"} %d\n", p2p["in"], p2p["out"]
        }'
}

# Bytes per network for one container: match each interface to its network by MAC
netbytes() {
    local c=$1 p=$2
    {
        # shellcheck disable=SC2016 # a docker template, not shell
        dk inspect -f '{{range $k, $v := .NetworkSettings.Networks}}NET {{$k}} {{$v.MacAddress}}{{"\n"}}{{end}}' "$c"
        nsenter -t "$p" -n ip -o link | awk '{ for (i = 1; i < NF; i++) if ($i == "link/ether") { n = $2; sub(/:$/, "", n); sub(/@.*/, "", n); print "IF", n, $(i + 1) } }'
        sed -n 's/^ *\([^:]*\): *\(.*\)$/DEV \1 \2/p' "/proc/$p/net/dev"
    } | awk -v c="$c" '
        $1 == "NET" { net = $2; sub(/.*_/, "", net); bymac[$3] = net }
        $1 == "IF" { ifmac[$2] = $3 }
        $1 == "DEV" { rx[$2] = $3; tx[$2] = $11 }
        END {
            for (i in ifmac) if (ifmac[i] in bymac && i in rx) {
                printf "capacity_netns_network_bytes_total{container=\"%s\",network=\"%s\",direction=\"rx\"} %s\n", c, bymac[ifmac[i]], rx[i]
                printf "capacity_netns_network_bytes_total{container=\"%s\",network=\"%s\",direction=\"tx\"} %s\n", c, bymac[ifmac[i]], tx[i]
                found++
            }
            exit found == 0
        }'
}

# --- Kernel TCP counters and bytes per network in the namespace of a container
netns_part() {
    local c=$1 p=${PID[$1]:-0}
    ((p > 0))
    awk -v c="$c" '
        /^TcpExt:/ { if (!h) { for (i = 2; i <= NF; i++) k[i] = $i; h = 1 }
                     else for (i = 2; i <= NF; i++) if (k[i] ~ /^(TCPAbortOnClose|TCPAbortOnData|TCPAbortOnTimeout|ListenOverflows|ListenDrops)$/)
                         printf "capacity_netns_tcpext_total{container=\"%s\",counter=\"%s\"} %s\n", c, k[i], $i }' "/proc/$p/net/netstat"
    awk -v c="$c" '
        /^Tcp:/ { if (!h) { for (i = 2; i <= NF; i++) k[i] = $i; h = 1 }
                  else for (i = 2; i <= NF; i++) {
                      if (k[i] ~ /^(ActiveOpens|PassiveOpens|AttemptFails|EstabResets)$/) printf "capacity_netns_tcp_total{container=\"%s\",counter=\"%s\"} %s\n", c, k[i], $i
                      if (k[i] == "CurrEstab") printf "capacity_netns_tcp_curr_estab{container=\"%s\"} %s\n", c, $i } }' "/proc/$p/net/snmp"
    netbytes "$c" "$p"
}

# --- Process and cgroup use of a container (cgroup v2)
cgroup_part() {
    local c=$1 p=${PID[$1]:-0} id=${CID[$1]:-} cg quota period mm pm
    printf 'capacity_container_start_time_seconds{container="%s"} %s\n' "$c" "$(date -d "${STARTED[$c]}" +%s)"
    printf 'capacity_process_open_fds{container="%s"} %s\n' "$c" "$(find "/proc/$p/fd" -mindepth 1 -maxdepth 1 | wc -l)"
    printf 'capacity_process_fd_soft_limit{container="%s"} %s\n' "$c" "$(awk '/^Max open files/ {print $4}' "/proc/$p/limits")"
    printf 'capacity_process_threads{container="%s"} %s\n' "$c" "$(awk '/^Threads:/ {print $2}' "/proc/$p/status")"
    # systemd cgroup driver (the boxes), else cgroupfs
    cg=$CGROUP_ROOT/system.slice/docker-$id.scope
    [[ -d $cg ]] || cg=$CGROUP_ROOT/docker/$id
    [[ -d $cg ]]
    awk -v c="$c" '
        $1 == "usage_usec" { printf "capacity_cgroup_cpu_usage_seconds_total{container=\"%s\"} %.3f\n", c, $2 / 1e6 }
        $1 == "nr_periods" { printf "capacity_cgroup_cpu_periods_total{container=\"%s\"} %s\n", c, $2 }
        $1 == "nr_throttled" { printf "capacity_cgroup_cpu_throttled_periods_total{container=\"%s\"} %s\n", c, $2 }' "$cg/cpu.stat"
    read -r quota period <"$cg/cpu.max"
    if [[ $quota != max ]]; then
        awk -v c="$c" -v q="$quota" -v p="$period" 'BEGIN { printf "capacity_cgroup_cpu_limit_cores{container=\"%s\"} %.3f\n", c, q / p }'
    fi
    printf 'capacity_cgroup_memory_bytes{container="%s"} %s\n' "$c" "$(cat "$cg/memory.current")"
    awk -v c="$c" '$1 == "anon" { printf "capacity_cgroup_memory_anon_bytes{container=\"%s\"} %s\n", c, $2 }' "$cg/memory.stat"
    mm=$(cat "$cg/memory.max")
    if [[ $mm != max ]]; then printf 'capacity_cgroup_memory_limit_bytes{container="%s"} %s\n' "$c" "$mm"; fi
    awk -v c="$c" '$1 == "oom_kill" { printf "capacity_cgroup_oom_kills_total{container=\"%s\"} %s\n", c, $2 }' "$cg/memory.events"
    printf 'capacity_cgroup_pids{container="%s"} %s\n' "$c" "$(cat "$cg/pids.current")"
    pm=$(cat "$cg/pids.max")
    if [[ $pm != max ]]; then printf 'capacity_cgroup_pids_limit{container="%s"} %s\n' "$c" "$pm"; fi
}

# --- Host network (this script runs in the host namespace)
host_net_part() {
    local dev rx tx month state smonth slast stotal delta
    dev=$(ip route show default | awk '{print $5; exit}')
    [[ -n $dev && -r /sys/class/net/$dev/statistics/tx_bytes ]]
    rx=$(cat "/sys/class/net/$dev/statistics/rx_bytes")
    tx=$(cat "/sys/class/net/$dev/statistics/tx_bytes")
    printf 'capacity_host_network_bytes_total{device="%s",direction="rx"} %s\n' "$dev" "$rx"
    printf 'capacity_host_network_bytes_total{device="%s",direction="tx"} %s\n' "$dev" "$tx"
    # Egress in this calendar month (UTC). State line: <YYYY-MM> <last tx counter> <month total>
    month=$(date -u +%Y-%m) state=$STATE_DIR/traffic-month
    if ! read -r smonth slast stotal 2>/dev/null <"$state"; then smonth=$month slast=$tx stotal=0; fi
    [[ $smonth == "$month" ]] || stotal=0
    if ((tx >= slast)); then delta=$((tx - slast)); else delta=$tx; fi # a reboot resets the counter
    stotal=$((stotal + delta))
    printf '%s %s %s\n' "$month" "$tx" "$stotal" >"$state.tmp"
    mv "$state.tmp" "$state"
    printf 'capacity_host_tx_month_bytes %s\ncapacity_traffic_included_bytes %s\n' "$stotal" "$INCLUDED_TRAFFIC_BYTES"
}

host_tcp_part() {
    if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        printf 'capacity_host_conntrack_entries %s\ncapacity_host_conntrack_limit %s\n' \
            "$(cat /proc/sys/net/netfilter/nf_conntrack_count)" "$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
    fi
    awk '/^TcpExt:/ { if (!h) { for (i = 2; i <= NF; i++) k[i] = $i; h = 1 }
                      else for (i = 2; i <= NF; i++) if (k[i] ~ /^(ListenOverflows|ListenDrops)$/) printf "capacity_host_tcpext_total{counter=\"%s\"} %s\n", k[i], $i }' /proc/net/netstat
}

# --- New clearnet connections per published port (one DNAT match per connection)
dnat_part() {
    iptables -t nat -L DOCKER -v -n -x | awk '
        /DNAT/ { for (i = 1; i <= NF; i++) if ($i ~ /^dpt:/) n[substr($i, 5)] += $1 }
        END { for (p in n) printf "capacity_new_connections_total{port=\"%s\"} %d\n", p, n[p] }'
}

# --- Onion side: Tor client streams and the onion-proxy counters (stub_status)
onion_proxy_part() {
    local o=${PID[onion-proxy]:-0} s
    ((o > 0))
    printf 'capacity_onion_socket_clients %s\n' "$(nsenter -t "$o" -n ss -Hx state established | grep -c 'monerod\.sock' || true)"
    s=$(nsenter -t "$o" -n curl -sf -m 5 http://127.0.0.1:8081/status)
    awk '/^Active connections/ { printf "capacity_onion_proxy_connections{state=\"active\"} %s\n", $3 }
         /^ *[0-9]+ +[0-9]+ +[0-9]+ *$/ { printf "capacity_onion_proxy_accepts_total %s\ncapacity_onion_proxy_handled_total %s\ncapacity_onion_proxy_requests_total %s\n", $1, $2, $3 }
         /^Reading/ { printf "capacity_onion_proxy_connections{state=\"reading\"} %s\ncapacity_onion_proxy_connections{state=\"writing\"} %s\ncapacity_onion_proxy_connections{state=\"waiting\"} %s\n", $2, $4, $6 }' <<<"$s"
}

# --- Tor onion-service metrics (MetricsPort, loopback in the tor namespace)
tor_part() {
    local t=${PID[tor]:-0} s
    ((t > 0))
    s=$(nsenter -t "$t" -n curl -sf -m 5 http://127.0.0.1:9035/metrics)
    # Drop the onion label: the onion name stays out of Prometheus
    grep '^tor_hs_' <<<"$s" | sed -E 's/onion="[^"]*",?//; s/,\}/}/; s/\{\}//' || true
}

# The parts of a container run only while it runs. Container Down covers a
# stopped container, so its parts do not count as failed.
running() { [[ ${PID[$1]:-0} -gt 0 && -n ${CID[$1]:-} ]]; }

if running monerod; then run rpc rpc_part; fi
for c in monerod onion-proxy tor; do
    if running "$c"; then run "netns_$c" netns_part "$c"; fi
done
for c in "${CONTAINERS[@]}"; do
    if running "$c"; then run "cgroup_$c" cgroup_part "$c"; fi
done
run host_net host_net_part
run host_tcp host_tcp_part
run dnat dnat_part
if running onion-proxy; then run onion_proxy onion_proxy_part; fi
if running tor; then run tor tor_part; fi
printf 'capacity_metrics_last_run_timestamp_seconds %s\n' "$(date +%s)" >>"$RAW"

# One bad line makes node-exporter drop the whole file, so keep only
# well-formed lines. Sorting puts the lines of each metric together.
awk 'NF == 2 && $2 ~ /^[-+]?[0-9][0-9.eE+-]*$/' "$RAW" | LC_ALL=C sort >"$TMP"
chmod 644 "$TMP"
mv "$TMP" "$OUT"
