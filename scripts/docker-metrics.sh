#!/usr/bin/env bash
# Writes the state of this stack's containers for the node-exporter textfile
# collector, so Grafana can alert on stopped, crashing or unhealthy containers.
# Cron runs it every minute (scripts/docker-metrics.cron, installed as
# /etc/cron.d/monero-node-docker-metrics by setup.sh and the deploy workflow).
set -euo pipefail

PROJECT="${COMPOSE_PROJECT:-monero-node}"
DIR="${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}"
OUT="${DIR}/docker.prom"

mkdir -p "${DIR}"
TMP=$(mktemp "${DIR}/.docker.prom.XXXXXX")
trap 'rm -f "${TMP}"' EXIT

mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}")
# No containers at all: exit without a new file, so Container Metrics Stale fires
[ "${#ids[@]}" -gt 0 ] || exit 1

docker inspect --format \
    '{{.Name}} {{.State.Running}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${ids[@]}" |
awk -v now="$(date +%s)" '
{
    name = substr($1, 2)
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
