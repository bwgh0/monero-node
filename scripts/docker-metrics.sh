#!/usr/bin/env bash
# Writes the state of this stack's containers for the node-exporter textfile
# collector, so Grafana can alert on stopped, crashing or unhealthy containers.
# Cron runs it every minute (scripts/docker-metrics.cron, installed as
# /etc/cron.d/monero-node-docker-metrics by setup.sh and the deploy workflow).
# For tests: COMPOSE_PROJECT, TEXTFILE_DIR and LOCK_FILE.
set -euo pipefail

PROJECT="${COMPOSE_PROJECT:-monero-node}"
DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
OUT="${DIR}/docker.prom"
# A hung dockerd must not hang the cron job: each docker call gets 10 s.
# A call that fails or times out writes no new file, so Container Metrics
# Stale fires.
dk() { timeout -k 5 10 docker "$@"; }

# One run at a time: a new run exits while the last run still runs.
exec 9>"${LOCK_FILE:-/run/monero-node-docker-metrics.lock}"
flock -n 9 || exit 0
mkdir -p "${DIR}"
TMP=$(mktemp "${DIR}/.docker.prom.XXXXXX")
trap 'rm -f "${TMP}"' EXIT

mapfile -t ids < <(dk ps -aq --filter "label=com.docker.compose.project=${PROJECT}")
# No containers, or docker ps failed: exit without a new file, so Container
# Metrics Stale fires
[ "${#ids[@]}" -gt 0 ] || exit 1

dk inspect --format \
    '{{.Name}} {{.State.Running}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${ids[@]}" |
awk -v now="$(date +%s)" '
{
    name = substr($1, 2)
    # While compose recreates a container, a container has a temporary name:
    # 12 hex digits, "_" and the container name. Skip it. The next run shows
    # the container under its own name.
    if (index(name, "_") == 13 && substr(name, 1, 12) !~ /[^0-9a-f]/) next
    running[name] = ($2 == "true") ? 1 : 0
    restarts[name] = $3
    health[name] = $4
}
END {
    print "# HELP docker_container_running 1 if the container is running."
    print "# TYPE docker_container_running gauge"
    for (n in running) printf "docker_container_running{name=\"%s\"} %d\n", n, running[n]
    print "# HELP docker_container_restart_count Restarts by the restart policy since the container was created."
    print "# TYPE docker_container_restart_count counter"
    for (n in restarts) printf "docker_container_restart_count{name=\"%s\"} %d\n", n, restarts[n]
    print "# HELP docker_container_unhealthy 1 if the healthcheck reports unhealthy. Only containers with a healthcheck."
    print "# TYPE docker_container_unhealthy gauge"
    for (n in health) if (health[n] != "none") printf "docker_container_unhealthy{name=\"%s\"} %d\n", n, (health[n] == "unhealthy") ? 1 : 0
    print "# HELP docker_metrics_last_run_timestamp_seconds When this file was written."
    print "# TYPE docker_metrics_last_run_timestamp_seconds gauge"
    printf "docker_metrics_last_run_timestamp_seconds %d\n", now
}' > "${TMP}"

chmod 644 "${TMP}"
mv "${TMP}" "${OUT}"
