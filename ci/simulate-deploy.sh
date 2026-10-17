#!/usr/bin/env bash
# Local test of scripts/deploy.sh against a throwaway box. It never touches
# a real box. It builds a bare git origin, a clone with its own .env, and
# the stack running from that clone, like /opt/monero-node on a box. Then
# it deploys broken commits and checks that each one rolls back, and it
# deploys good commits that must pass. On a Mac:
#   CI_WORKDIR=<dir> ci/in-box.sh ci/simulate-deploy.sh
set -Eeuo pipefail
shopt -s inherit_errexit

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=ci/lib.sh
source "$root/ci/lib.sh"

work=$(mktemp -d "${SIM_WORKDIR:-${RUNNER_TEMP:-/tmp}}/mnsim.XXXXXX")
export COMPOSE_PROJECT_NAME=mnsim
export COMPOSE_FILE=docker-compose.yml:ci/docker-compose.ci.yml
export DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM:-linux/amd64}
domain=sim.node.monero.invalid
origin=$work/origin.git
dev=$work/dev
box=$work/box/monero-node
backups=$work/backups
# A valid onion name that this box does not have
wrong_onion=zu3oyzi45x3ul24sncs4245nlpz76jzizm36tvrkfvq2r33azzjv5syd.onion
results=()
rc=0

finish() {
    local status=$?
    trap - EXIT
    if cd "$box" 2>/dev/null; then
        if ((status != 0)); then
            step "FAILED. State of the stack:"
            dump_stack || true
        fi
        step "tear down"
        teardown
    fi
    rm -rf "$work"
    step "results"
    printf '%s\n' "${results[@]}"
    exit "$status"
}
trap finish EXIT

g() { git -C "$dev" -c user.name=sim -c user.email=sim@example.invalid "$@"; }

# change <message> <command...>: change dev, commit on top of base, push to main, print the sha
change() {
    local message=$1
    shift
    g reset -q --hard "$base"
    (cd "$dev" && "$@")
    g commit -qam "$message"
    g push -qf origin HEAD:main
    g rev-parse HEAD
}

deploy_env=(
    REPO_DIR="$box" STATE_DIR="$work/state" BACKUP_DIR="$backups" BACKUP_KEEP=3 HOST_SETUP=0
    WAIT_TIMEOUT=240 GATE_TIMEOUT=240 STABLE_SECONDS=15
)

# deploy <command> <sha> [onion]: runs deploy.sh as the workflow does. Sets rc.
deploy() {
    local -a extra=()
    if [[ $1 == start ]]; then
        extra=(--run-dir "$work/state/runs/sim-$2")
    fi
    set +e
    env "${deploy_env[@]}" bash "$root/scripts/deploy.sh" "$1" "${extra[@]}" \
        --target "$2" --domain "$domain" --onion "${3:-$onion}" 2>&1 | sed -u 's/^/  box| /'
    rc=${PIPESTATUS[0]}
    set -e
}

ids() {
    docker ps -a --filter label=com.docker.compose.project=mnsim --filter label=com.docker.compose.oneoff=False \
        --format '{{.Label "com.docker.compose.service"}} {{.ID}}' | sort
}
started() { docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$(docker compose ps -aq "$1")"; }
ips() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(docker compose ps -aq "$1")"; }

want_rc() { [[ $rc == "$1" ]] || bad "deploy exit code $rc, expected $1"; }
want_head() { [[ $(git -C "$box" rev-parse HEAD) == "$1" ]] || bad "the box is on $(git -C "$box" rev-parse --short HEAD), expected ${1:0:7}"; }
want_all_running() {
    local svc id state
    local -a services
    mapfile -t services < <(docker compose config --services)
    for svc in "${services[@]}"; do
        id=$(docker compose ps -aq "$svc")
        [[ -n $id ]] || bad "$svc has no container"
        state=$(docker inspect -f '{{.State.Status}}' "$id")
        [[ $state == running ]] || bad "$svc is $state"
    done
}
want_same_onion() {
    [[ $(onion_name) == "$onion" ]] || bad "the onion name changed"
    [[ $(onion_key_sha256) == "$key" ]] || bad "the onion key changed"
}
want_monerod_untouched() { [[ $(started monerod) == "$monerod_started" ]] || bad "monerod restarted"; }
record() { results+=("PASS  $1 ($((SECONDS - t0))s)"); }

step "build the throwaway box in $work"
git init -q --bare -b main "$origin"
git init -q -b main "$dev"
g remote add origin "$origin"
copy_tree "$root" "$dev"
g add -A
g commit -qm "base: the tree under test"
g push -q origin HEAD:main
base=$(g rev-parse HEAD)
git clone -q "$origin" "$box"
sed -e "s/^DOMAIN=.*/DOMAIN=$domain/" -e "s/^MONEROD_VOLUME=.*/MONEROD_VOLUME=mnsim_bitmonero/" \
    "$root/ci/ci.env" >"$box/.env"
mkdir -p "$box/aws" "$backups"
# A hand-made backup. Rotation must keep it.
touch "$backups/tor-keys-2026-10-16.tgz"
chmod 600 "$backups/tor-keys-2026-10-16.tgz"
cd "$box"
docker compose pull --quiet
REPO_DIR=$box bash "$root/scripts/deploy.sh" render --domain "$domain"
seed_certs "$domain"
seed_tor_dir
docker compose up -d --wait --wait-timeout 300
onion=$(onion_name) || bad "tor wrote no onion name"
key=$(onion_key_sha256)
monerod_started=$(started monerod)
ok "the box runs ${base:0:7}, onion $onion"

step "case A, the incident: tor cannot start (bad entrypoint)"
t0=$SECONDS
sha=$(change "break the tor entrypoint" sed -i 's|entrypoint: \["tor"\]|entrypoint: ["/usr/bin/tor"]|' docker-compose.yml)
[[ $(git -C "$dev" show "$sha:docker-compose.yml" | grep -c '"/usr/bin/tor"') == 2 ]] || bad "the case A change did not apply"
deploy deploy "$sha"
want_rc 1
want_head "$base"
want_all_running
want_same_onion
want_monerod_untouched
record "A tor entrypoint broken: gate failed, rolled back to base, onion and key same, monerod untouched"

step "case B: prometheus.yml does not load"
t0=$SECONDS
sha=$(change "break prometheus.yml" sh -c 'printf "not_a_real_field: true\n" >> monitoring/prometheus.yml')
deploy deploy "$sha"
want_rc 1
want_head "$base"
want_all_running
[[ $(docker compose exec -T prometheus cat /etc/prometheus/prometheus.yml | sha256sum) == "$(sha256sum <monitoring/prometheus.yml)" ]] ||
    bad "prometheus does not run the base prometheus.yml"
want_monerod_untouched
record "B prometheus.yml invalid: rolled back, prometheus runs the base file again, monerod untouched"

step "case C: tor gets a new HiddenServiceDir, so a new onion name"
t0=$SECONDS
sha=$(change "move the onion key dir" sed -i 's|^      - /var/lib/tor/hidden_service/monerod$|      - /var/lib/tor/hidden_service/monerod-new|' docker-compose.yml)
[[ $(git -C "$dev" show "$sha:docker-compose.yml" | grep -c 'hidden_service/monerod-new$') == 1 ]] || bad "the case C change did not apply"
deploy deploy "$sha"
want_rc 1
want_head "$base"
want_all_running
want_same_onion
want_monerod_untouched
record "C onion dir moved: the onion check failed, rolled back, onion and key same"

step "case F: an image tag that does not exist"
t0=$SECONDS
before=$(ids)
sha=$(change "use a missing grafana tag" sed -i 's|image: grafana/grafana:11.5.2|image: grafana/grafana:0.0.0-does-not-exist|' docker-compose.yml)
deploy deploy "$sha"
want_rc 1
want_head "$base"
want_all_running
[[ $(ids) == "$before" ]] || bad "a container changed after a failed pull"
record "F missing image: pull failed, rolled back, no container changed"

step "case D: a good change to prometheus.yml (run detached, as the workflow does)"
t0=$SECONDS
before=$(ids)
sha=$(change "a good prometheus.yml change" sh -c 'printf "# a harmless change\n" >> monitoring/prometheus.yml')
deploy start "$sha"
want_rc 0
want_head "$sha"
want_all_running
want_same_onion
want_monerod_untouched
changed=$({ diff <(printf '%s\n' "$before") <(ids) || true; } | awk '/^>/ { print $2 }' | sort -u | paste -sd ' ' -)
[[ $changed == prometheus ]] || bad "the deploy recreated: ${changed:-nothing}, expected only prometheus"
record "D good prometheus.yml change: deployed, recreated only prometheus"

step "case E: the onion pin does not match the box"
t0=$SECONDS
before=$(ids)
deploy deploy "$sha" "$wrong_onion"
want_rc 3
want_head "$sha"
[[ $(ids) == "$before" ]] || bad "a container changed"
record "E wrong onion pin: stopped before any change"

step "case G: a change to monerod only. The rpc proxy must follow the new monerod."
t0=$SECONDS
proxy_started=$(started monerod-rpc-proxy)
monerod_ips=$(ips monerod)
sha=$(change "label monerod" sed -i -e '/^  monerod:$/a\    labels:' -e '/^  monerod:$/a\      - sim.case=g' docker-compose.yml)
[[ $(git -C "$dev" show "$sha:docker-compose.yml" | grep -c 'sim.case=g') == 1 ]] || bad "the case G change did not apply"
deploy deploy "$sha"
want_rc 0
want_head "$sha"
want_all_running
want_same_onion
[[ $(started monerod) != "$monerod_started" ]] || bad "monerod was not recreated"
[[ $(started monerod-rpc-proxy) != "$proxy_started" ]] || bad "monerod-rpc-proxy did not restart after monerod"
moved="monerod kept its IP"
[[ $(ips monerod) == "$monerod_ips" ]] || moved="monerod got a new IP"
record "G monerod change: deployed, rpc proxy restarted and the gate passed ($moved)"

step "onion key backups"
mapfile -t made < <(find "$backups" -name 'tor-keys-????????T??????Z.tgz' | sort)
((${#made[@]} == 3)) || bad "${#made[@]} rotating backups, expected 3 (BACKUP_KEEP=3 after 6 deploys)"
[[ -e $backups/tor-keys-2026-10-16.tgz ]] || bad "rotation removed the hand-made backup"
for f in "${made[@]}"; do
    [[ $(stat -c %a "$f") == 600 ]] || bad "$f has mode $(stat -c %a "$f")"
done
[[ $(tar -xzOf "${made[-1]}" ./monerod/hs_ed25519_secret_key | sha256sum | cut -d ' ' -f 1) == "$key" ]] ||
    bad "the newest backup does not hold the onion key"
results+=("PASS  backups: 3 kept of 6 (BACKUP_KEEP=3), mode 600, newest holds the key, hand-made backup kept")
