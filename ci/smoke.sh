#!/usr/bin/env bash
# Boots the whole stack on amd64 the way a deploy does, with dummy secrets
# (ci/ci.env), a self-signed cert and an offline monerod. Then it runs the
# deploy gate (scripts/deploy.sh gate) and checks what Grafana loaded.
#
# CI runs it on every pull request and before every deploy. It needs docker
# with compose, git, curl, openssl and python3, and free ports 80, 443,
# 18080 and 18089. On a Mac: CI_WORKDIR=<dir> ci/in-box.sh ci/smoke.sh
set -Eeuo pipefail
shopt -s inherit_errexit

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=ci/lib.sh
source "$root/ci/lib.sh"

work=${SMOKE_WORKDIR:-${RUNNER_TEMP:-/tmp}}
repo=$(mktemp -d "$work/mnci.XXXXXX")
export COMPOSE_PROJECT_NAME=mnci
export COMPOSE_FILE=docker-compose.yml:ci/docker-compose.ci.yml
export DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM:-linux/amd64}
domain=$(sed -n 's/^DOMAIN=//p' "$root/ci/ci.env")
password=$(sed -n 's/^GRAFANA_PASSWORD=//p' "$root/ci/ci.env")
gate_env=(REPO_DIR="$repo" HOST_SETUP=0 GATE_TIMEOUT=300 STABLE_SECONDS=20)

finish() {
    local rc=$?
    trap - EXIT
    if cd "$repo" 2>/dev/null; then
        if ((rc != 0)); then
            step "FAILED. State of the stack:"
            dump_stack || true
        fi
        step "tear down"
        teardown
    fi
    rm -rf "$repo"
    exit "$rc"
}
trap finish EXIT

step "copy the tree to a work dir"
copy_tree "$root" "$repo"
cp "$root/ci/ci.env" "$repo/.env"
mkdir -p "$repo/aws"
cd "$repo"
ok "$repo"

step "compose config"
COMPOSE_FILE=docker-compose.yml docker compose config -q
docker compose config -q
ok "docker-compose.yml is valid, alone and with the CI override"

step "pull every image ($DOCKER_DEFAULT_PLATFORM)"
docker compose pull --quiet
ok "pulled $(docker compose config --images | sort -u | wc -l) images"

step "fill the templates, as a deploy does"
REPO_DIR=$repo bash scripts/deploy.sh render --domain "$domain"
# shellcheck disable=SC2016 # the literal template text
if grep -qF '${DOMAIN}' nginx.conf onion-proxy.conf monitoring/grafana/provisioning/alerting/*.yml; then
    bad "nginx.conf, onion-proxy.conf or an alert rule file still has \${DOMAIN}"
fi
grep -qF "domain=\"$domain\"" monitoring/grafana/provisioning/alerting/probe-rules.yml ||
    bad "the probe rules do not name $domain"
grep -qF "/etc/letsencrypt/live/$domain/fullchain.pem" onion-proxy.conf ||
    bad "onion-proxy.conf does not name the cert of $domain"
ok "nginx.conf, onion-proxy.conf and the alert rules name $domain"

# onion-proxy loads the cert at start, so nginx -t needs it too
step "seed a self-signed cert and the onion key dir"
seed_certs "$domain"
seed_tor_dir
ok "seeded"

step "check the configs with the pinned images"
check() {
    local entrypoint=$1 service=$2
    shift 2
    if ! docker compose run --rm --no-deps -T --entrypoint "$entrypoint" "$service" "$@" 2>&1 | mask; then
        bad "$service: $entrypoint $* failed"
    fi
    ok "$service: $entrypoint $*"
}
check nginx nginx -t -q
check nginx onion-proxy -t -q
# monerod-rpc-proxy names monerod in a fixed upstream, so nginx must
# resolve it to load the config. Its check runs once the stack is up.
check promtool prometheus check config /etc/prometheus/prometheus.yml
check /bin/blackbox_exporter blackbox --config.file=/etc/blackbox_exporter/config.yml --config.check

step "boot the stack"
docker compose up -d --wait --wait-timeout 300
ok "docker compose up --wait passed"

step "every container runs a ${DOCKER_DEFAULT_PLATFORM#linux/} image"
mapfile -t ids < <(docker compose ps -aq)
for id in "${ids[@]}"; do
    read -r name image < <(docker inspect -f '{{.Name}} {{.Image}}' "$id")
    arch=$(docker image inspect -f '{{.Architecture}}' "$image")
    [[ $arch == "${DOCKER_DEFAULT_PLATFORM#linux/}" ]] || bad "${name#/} runs an $arch image"
done
ok "${#ids[@]} containers"

step "check the rpc proxy config, now that monerod resolves"
if ! docker compose exec -T monerod-rpc-proxy nginx -t -q 2>&1 | mask; then
    bad "monerod-rpc-proxy: nginx -t -q failed"
fi
ok "monerod-rpc-proxy: nginx -t -q"

# A Tor with an empty cache downloads all the relay descriptors. Now and
# then it stalls at "Loading relay descriptors" for minutes on a runner,
# while the next start bootstraps in seconds (2026-10-17: 2 smoke runs failed
# so). The boxes keep their Tor cache. So give each Tor 150 s, restart a
# stalled one once, and then let the gate judge it as before.
tor_bootstrapped_ci() {
    local svc=$1 i logs
    for ((i = 0; i < 30; i++)); do
        # A variable, not a pipe to grep -q: with pipefail, an early exit of
        # grep can fail the pipe.
        logs=$(docker compose logs --no-log-prefix "$svc" 2>/dev/null) || logs=""
        [[ $logs != *"Bootstrapped 100%"* ]] || return 0
        sleep 5
    done
    return 1
}
restart_stalled_tor() {
    local svc
    for svc in tor tor-client; do
        tor_bootstrapped_ci "$svc" && continue
        printf 'warn  %s\n' "$svc did not bootstrap in 150 s. Restart it once."
        docker compose restart "$svc"
    done
}

step "deploy gate"
onion=$(onion_name) || bad "tor wrote no onion name"
key=$(onion_key_sha256)
restart_stalled_tor
env "${gate_env[@]}" bash scripts/deploy.sh gate --onion "$onion" --key-sha256 "$key"

step "recreate tor. The onion name and key must stay the same."
docker compose up -d --no-deps --force-recreate --wait tor
restart_stalled_tor
env "${gate_env[@]}" bash scripts/deploy.sh gate --onion "$onion" --key-sha256 "$key"

step "Grafana loaded all of the provisioning"
api() { curl -sf --max-time 10 -u "admin:$password" "http://localhost/grafana/api/$1"; }
count() { python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'; }
alerting=monitoring/grafana/provisioning/alerting
want_rules=$(cat "$alerting"/*.yml | grep -cE '^[[:space:]]+title:')
want_dashboards=$(find monitoring/grafana/provisioning/dashboards -name '*.json' | wc -l)
datasource=$(sed -n 's/^[[:space:]]*uid:[[:space:]]*//p' monitoring/grafana/provisioning/datasources/prometheus.yml | head -n 1)
receiver=$(sed -n 's/^[[:space:]]*receiver:[[:space:]]*//p' "$alerting/policies.yml" | head -n 1)
rules=0 dashboards=0
for ((i = 0; i < 24; i++)); do
    rules=$(api v1/provisioning/alert-rules | count) || rules=0
    dashboards=$(api 'search?type=dash-db' | count) || dashboards=0
    if ((rules == want_rules && dashboards == want_dashboards)); then
        break
    fi
    sleep 5
done
((rules == want_rules)) || bad "Grafana has $rules alert rules, the files define $want_rules"
ok "$rules alert rules"
api v1/provisioning/alert-rules | python3 -c '
import json, sys
exprs = [q["model"].get("expr", "") for r in json.load(sys.stdin) for q in r["data"]]
sys.exit(0 if any("domain=\"%s\"" % sys.argv[1] in e for e in exprs) else 1)' "$domain" ||
    bad "the loaded alert rules do not select the probes of $domain"
ok "the loaded alert rules select the probes of $domain"
# A rule whose query fails must keep its last state (execErrState KeepLast),
# so a Prometheus restart sends no false CLEARED. Only
# Prometheus Unreachable alerts when its query fails or has no data, after 3
# minutes or more.
errstate=$(api v1/provisioning/alert-rules | python3 -c '
import json, re, sys
def seconds(d):
    return sum(int(n) * {"h": 3600, "m": 60, "s": 1}[u] for n, u in re.findall(r"([0-9]+)([hms])", d or ""))
rules = json.load(sys.stdin)
out = [] if any(r["title"] == "Prometheus Unreachable" for r in rules) else ["Prometheus Unreachable (missing)"]
for r in rules:
    if r["title"] == "Prometheus Unreachable":
        if (r.get("execErrState"), r.get("noDataState")) != ("Alerting", "Alerting") or seconds(r.get("for")) < 180:
            out.append(r["title"])
    elif r.get("execErrState") != "KeepLast":
        out.append(r["title"])
print(", ".join(out))')
[[ -z $errstate ]] || bad "these alert rules have the wrong error or no data state: $errstate"
ok "each alert rule keeps its last state when its query fails, and Prometheus Unreachable alerts"
api v1/provisioning/templates | python3 -c '
import json, sys
sys.exit(0 if any(t.get("name") == "monero" for t in json.load(sys.stdin)) else 1)' ||
    bad "Grafana has no notification template monero"
ok "notification template monero"
((dashboards == want_dashboards)) || bad "Grafana has $dashboards dashboards, the files define $want_dashboards"
ok "$dashboards dashboards"
health=$(api "datasources/uid/$datasource/health") || health=""
[[ $health =~ \"status\"[[:space:]]*:[[:space:]]*\"OK\" ]] ||
    bad "the Prometheus data source $datasource does not answer"
ok "data source $datasource reaches Prometheus"
api v1/provisioning/contact-points | python3 -c '
import json, sys
names = [c["name"] for c in json.load(sys.stdin)]
sys.exit(0 if sys.argv[1] in names else 1)' "$receiver" || bad "Grafana has no contact point $receiver"
api v1/provisioning/policies | python3 -c '
import json, sys
sys.exit(0 if json.load(sys.stdin).get("receiver") == sys.argv[1] else 1)' "$receiver" ||
    bad "the notification policy does not send to $receiver"
ok "alerts go to contact point $receiver"
# A rule with no data alerts at once as DatasourceNoData (noDataState NoData
# skips the pending period), and Grafana ends the alert only 4 minutes after
# the last evaluation with no data. So the DatasourceNoData route of
# policies.yml must wait 7 minutes or more: then a gap in the data of up to 3
# minutes sends no message.
api v1/provisioning/policies | python3 -c '
import json, re, sys
def seconds(d):
    return sum(int(n) * {"h": 3600, "m": 60, "s": 1}[u] for n, u in re.findall(r"([0-9]+)([hms])", d or ""))
routes = json.load(sys.stdin).get("routes") or []
sys.exit(0 if any("DatasourceNoData" in json.dumps(r.get("object_matchers")) and seconds(r.get("group_wait")) >= 420
                  for r in routes) else 1)' ||
    bad "the notification policy has no DatasourceNoData route that waits 7 minutes or more"
ok "DatasourceNoData alerts wait 7 minutes or more before a message"
# The repo has no provisioning/plugins dir. Grafana logs that as an error.
errors=$(docker compose logs --no-color grafana 2>&1 | grep -E 'level=(error|crit)' | grep -iE 'provision' |
    grep -vE 'Failed to read plugin provisioning files from directory.*no such file or directory' || true)
if [[ -n $errors ]]; then
    printf '%s\n' "$errors" | mask
    bad "Grafana logged provisioning errors"
fi
ok "no provisioning errors in the Grafana log"

step "PASS: the stack boots on ${DOCKER_DEFAULT_PLATFORM#linux/} and passes the deploy gate"
