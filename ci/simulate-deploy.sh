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
# Case J: a "new" monerod image, a local tag of the one in docker-compose.yml
monerod_image=ghcr.io/sethforprivacy/simple-monerod:v0.18.4.5
new_monerod=mnsim-local/simple-monerod:sim-j
# Case M: a new monerod image that cannot start
broken_monerod=mnsim-local/simple-monerod:sim-m
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
    docker rm -fv mnsim-broken-monerod >/dev/null 2>&1 || true
    docker rmi "$new_monerod" "$broken_monerod" >/dev/null 2>&1 || true
    rm -rf "$work"
    step "results"
    printf '%s\n' "${results[@]}"
    exit "$status"
}
trap finish EXIT

g() { git -C "$dev" -c user.name=sim -c user.email=sim@example.invalid "$@"; }

# change_from <sha> <message> <command...>: change dev, commit on top of
# <sha>, push to main, print the sha
change_from() {
    local from=$1 message=$2
    shift 2
    g reset -q --hard "$from"
    (cd "$dev" && "$@")
    g commit -qam "$message"
    g push -qf origin HEAD:main
    g rev-parse HEAD
}
# change <message> <command...>: the same on top of base
change() { change_from "$base" "$@"; }

deploy_env=(
    REPO_DIR="$box" STATE_DIR="$work/state" BACKUP_DIR="$backups" BACKUP_KEEP=3 HOST_SETUP=0
    WAIT_TIMEOUT=240 GATE_TIMEOUT=240 PRE_GATE_TIMEOUT=30 STABLE_SECONDS=15
)

runs=$work/state/runs
run_n=0
extra_env=() # more env for the next deploy only

# deploy <command> <sha> [onion]: runs deploy.sh as the workflow does, and
# keeps its output in $work/last.log. Sets rc.
deploy() {
    local -a args=()
    if [[ $1 == start ]]; then
        run_n=$((run_n + 1))
        args=(--run-dir "$runs/local-$run_n")
    fi
    set +e
    env "${deploy_env[@]}" "${extra_env[@]}" bash "$root/scripts/deploy.sh" "$1" "${args[@]}" \
        --target "$2" --domain "$domain" --onion "${3:-$onion}" 2>&1 | sed -u 's/^/  box| /' | tee "$work/last.log"
    rc=${PIPESTATUS[0]}
    set -e
    extra_env=()
}

# deploy_ssh <sha> [run id] [more args]: runs scripts/deploy-ssh.sh as the
# workflow does, or with no run id ("") as a person does by hand (no
# SSH_KEY). A stand-in ssh runs the box commands here. Sets rc and known
# (the already_failing output).
deploy_ssh() {
    local sha=$1 run=${2:-}
    local -a how=(SSH_KEY= GITHUB_RUN_ID= GITHUB_ACTIONS=)
    shift $(($# < 2 ? $# : 2))
    if [[ -n $run ]]; then
        how=(SSH_KEY=not-a-key GITHUB_RUN_ID="$run" GITHUB_RUN_ATTEMPT=1)
    fi
    : >"$work/gh-output"
    set +e
    (
        cd "$root" &&
            env "${deploy_env[@]}" "${extra_env[@]}" "${how[@]}" PATH="$work/fake-ssh:$PATH" KNOWN_HOSTS="$work/known_hosts" \
                GITHUB_OUTPUT="$work/gh-output" RUNS_DIR="$runs" \
                scripts/deploy-ssh.sh sim.box.invalid "$domain" "$onion" "$sha" "$@"
    ) 2>&1 | sed -u 's/^/  ssh| /' | tee "$work/last.log"
    rc=${PIPESTATUS[0]}
    set -e
    extra_env=()
    grep -qx "rc=$rc" "$work/gh-output" || bad "deploy-ssh.sh wrote no rc=$rc output"
    known=$(sed -n 's/^already_failing=//p' "$work/gh-output")
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
# For deploy_ssh: a pinned host key, and an ssh that runs the command here
printf 'sim.box.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderNotARealKey0000000000000000\n' >"$work/known_hosts"
mkdir -p "$work/fake-ssh"
cat >"$work/fake-ssh/ssh" <<'FAKE'
#!/usr/bin/env bash
while (($#)); do
    case $1 in
        -i | -o) shift 2 ;;
        root@*) shift && break ;;
        *) echo "fake ssh: unexpected argument $1" >&2 && exit 255 ;;
    esac
done
exec bash -c "$*"
FAKE
chmod 755 "$work/fake-ssh/ssh"

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
grep -qE 'FAIL  tor(-client)? ' "$work/last.log" || bad "no FAIL line names tor"
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

step "case K: start refuses a bad --run-dir, and it deletes nothing"
t0=$SECONDS
# Old run dirs, a dir that is not a run, and a symlink to a dir of decoys.
# The decoys have run id names, so only the --run-dir check keeps them.
decoy=$work/decoy
mkdir -p "$decoy"/{1-1,2-1,3-1} "$runs"/{5-1,6-1,7-1,keep-me}
touch "$decoy/file"
touch -d 2026-01-05 "$runs/5-1"
touch -d 2026-01-06 "$runs/6-1"
touch -d 2026-01-07 "$runs/7-1"
ln -s "$decoy" "$runs/900-1"
listing() { find "$decoy" "$runs" /var/lib -maxdepth 1 | sort; }
listed=$(listing)
for run_dir in /var/lib/x "$runs/900-1" "$runs/../../decoy/4-1" "$runs/not-a-run" "$runs/" runs/8-1; do
    set +e
    env "${deploy_env[@]}" RUNS_KEEP=1 bash "$root/scripts/deploy.sh" start --run-dir "$run_dir" \
        --target "$base" --domain "$domain" --onion "$onion" >"$work/last.log" 2>&1
    rc=$?
    set -e
    want_rc 3
    grep -q -- '--run-dir must be' "$work/last.log" || bad "no clear error for --run-dir $run_dir"
done
[[ $(listing) == "$listed" ]] || bad "a refused --run-dir changed files"
[[ ! -e /var/lib/x && ! -e $decoy/1-1/pid ]] || bad "a refused --run-dir got a deploy"
record "K bad --run-dir (/var/lib/x, a symlink, .., a bad name, relative): refused with exit 3, nothing deleted"

step "case D: a good change to prometheus.yml (run detached, as the workflow does)"
t0=$SECONDS
before=$(ids)
sha=$(change "a good prometheus.yml change" sh -c 'printf "# a harmless change\n" >> monitoring/prometheus.yml')
extra_env=(RUNS_KEEP=2)
deploy start "$sha"
want_rc 0
want_head "$sha"
want_all_running
want_same_onion
want_monerod_untouched
changed=$({ diff <(printf '%s\n' "$before") <(ids) || true; } | awk '/^>/ { print $2 }' | sort -u | paste -sd ' ' -)
[[ $changed == prometheus ]] || bad "the deploy recreated: ${changed:-nothing}, expected only prometheus"
# RUNS_KEEP=2: this run and the newest old run stay. Other names stay too.
[[ -d $runs/local-1 && -d $runs/7-1 && -d $runs/keep-me && -L $runs/900-1 ]] || bad "prune removed a dir that it must keep"
[[ ! -e $runs/5-1 && ! -e $runs/6-1 ]] || bad "prune kept the old run dirs 5-1 and 6-1"
[[ $(find "$decoy" | sort | paste -sd ' ' -) == "$decoy $decoy/1-1 $decoy/2-1 $decoy/3-1 $decoy/file" ]] ||
    bad "prune changed the dir behind the symlink"
record "D good prometheus.yml change: deployed, recreated only prometheus; prune kept 2 runs, other dirs and the symlink"

step "case E: the onion pin does not match the box"
t0=$SECONDS
before=$(ids)
deploy deploy "$sha" "$wrong_onion"
want_rc 3
want_head "$sha"
[[ $(ids) == "$before" ]] || bad "a container changed"
record "E wrong onion pin: stopped before any change"

step "case L: a key sha256 pin that does not match, and a commit that tracks .env"
t0=$SECONDS
good=$sha
before=$(ids)
env_sum=$(sha256sum <"$box/.env")
set +e
env "${deploy_env[@]}" bash "$root/scripts/deploy.sh" deploy --target "$good" --domain "$domain" --onion "$onion" \
    --key-sha256 "$(printf '%064d' 0)" >"$work/last.log" 2>&1
rc=$?
set -e
want_rc 3
grep -q -- 'does not have the sha256 from --key-sha256' "$work/last.log" || bad "no clear error for a wrong --key-sha256"
sha=$(change "track .env" sh -c 'printf "DOMAIN=x\n" > .env && git add -f .env')
deploy deploy "$sha"
want_rc 3
grep -q -- 'tracks .env' "$work/last.log" || bad "no clear error for a commit that tracks .env"
want_head "$good"
[[ $(sha256sum <"$box/.env") == "$env_sum" ]] || bad "the box .env changed"
[[ $(ids) == "$before" ]] || bad "a container changed"
sha=$good
record "L wrong --key-sha256, and a commit that tracks .env: both stopped before any change, .env kept"

step "case H: a fault from before the deploy (no onion socket) causes no rollback"
t0=$SECONDS
docker compose exec -T onion-proxy rm -f /run/onion/monerod.sock
sha=$(change "a prometheus.yml comment for case H" sh -c 'printf "# case H\n" >> monitoring/prometheus.yml')
extra_env=(GATE_TIMEOUT=60)
deploy_ssh "$sha" 777
want_rc 0
want_head "$sha"
want_monerod_untouched
for check in "the onion socket exists in tor" "the onion socket answers plain HTTP" "the onion socket answers TLS"; do
    grep -qF "FAIL  $check (already failing before the change)" "$work/last.log" || bad "the log does not call this check already failing: $check"
    [[ $known == *"$check"* ]] || bad "already_failing does not name: $check"
done
grep -q 'WARN  fails before the change: the onion socket exists in tor' "$work/last.log" || bad "the gate before the change did not see the fault"
grep -q 'checks already failing::' "$work/last.log" || bad "deploy-ssh.sh did not warn about the checks"
docker compose up -d --no-deps --force-recreate onion-proxy >/dev/null 2>&1
for ((i = 0; i < 30; i++)); do
    docker compose exec -T tor test -S /run/onion/monerod.sock && break
    sleep 2
done
docker compose exec -T tor test -S /run/onion/monerod.sock || bad "the onion socket did not come back"
record "H fault from before: deployed (exit 0) with no rollback, log and already_failing name the 3 socket checks"

step "case I: a new fault (the rpc proxy points to a closed port) rolls back"
t0=$SECONDS
good=$sha
sha=$(change "point the rpc proxy to a closed port" sed -i 's|server monerod:18081;|server monerod:18099;|' monitoring/rpc-proxy.conf)
[[ $(git -C "$dev" show "$sha:monitoring/rpc-proxy.conf" | grep -c 'monerod:18099') == 1 ]] || bad "the case I change did not apply"
extra_env=(GATE_TIMEOUT=60)
deploy deploy "$sha"
want_rc 1
want_head "$good"
want_all_running
want_same_onion
want_monerod_untouched
grep -q 'FAIL  monerod-rpc-proxy reaches monerod$' "$work/last.log" || bad "the gate did not name the rpc proxy"
docker compose exec -T monerod-rpc-proxy curl -sf --max-time 10 http://localhost:18081/get_height >/dev/null ||
    bad "the rpc proxy does not reach monerod after the rollback"
sha=$good
record "I new fault: the rpc proxy check regressed, rolled back to H, the proxy works again"

step "case M: a new monerod image that never starts rolls back, because its data is as before"
t0=$SECONDS
good=$sha
# A copy of the monerod image whose entrypoint does not exist
docker create --name mnsim-broken-monerod "$monerod_image" >/dev/null
docker commit --change 'ENTRYPOINT ["/sim-no-monerod"]' mnsim-broken-monerod "$broken_monerod" >/dev/null
docker rm -v mnsim-broken-monerod >/dev/null
sha=$(change_from "$good" "a new monerod image that cannot start" sed -i "s|image: $monerod_image|image: $broken_monerod|" docker-compose.yml)
[[ $(git -C "$dev" show "$sha:docker-compose.yml" | grep -c "image: $broken_monerod") == 1 ]] || bad "the case M change did not apply"
deploy deploy "$sha"
want_rc 1
want_head "$good"
want_all_running
want_same_onion
grep -q "WARN  monerod keeps data in a volume, and its image changes from $monerod_image to $broken_monerod" "$work/last.log" ||
    bad "no warning before the monerod image change"
grep -q "monerod did not start on its new image $broken_monerod, so its data is as before" "$work/last.log" ||
    bad "the log does not say that the new monerod never started"
grep -q 'Roll back to' "$work/last.log" || bad "it did not roll back"
! grep -q 'MANUAL ACTION NEEDED' "$work/last.log" || bad "it asked for manual action, but the new monerod never started"
[[ $(docker inspect -f '{{.Config.Image}}' "$(docker compose ps -aq monerod)") == "$monerod_image" ]] ||
    bad "monerod does not run its old image after the rollback"
monerod_started=$(started monerod)
sha=$good
record "M new monerod image that never starts: rolled back (exit 1) to H, monerod runs its old image, onion and key same"

step "case J: a new monerod image and a broken tor in one commit: refused before any change"
t0=$SECONDS
before=$(ids)
docker tag "$monerod_image" "$new_monerod"
sha=$(change "a new monerod image, and a broken tor entrypoint" sed -i -e "s|image: $monerod_image|image: $new_monerod|" \
    -e 's|entrypoint: \["tor"\]|entrypoint: ["/usr/bin/tor"]|' docker-compose.yml)
[[ $(git -C "$dev" show "$sha:docker-compose.yml" | grep -c -e "image: $new_monerod" -e '"/usr/bin/tor"') == 3 ]] ||
    bad "the case J change did not apply"
deploy_ssh "$sha" 778
want_rc 3
want_head "$good"
[[ $(ids) == "$before" ]] || bad "a container changed"
want_monerod_untouched
grep -qF "FAIL  a service that keeps data gets a new image: monerod ($monerod_image to $new_monerod). The same deploy also changes: " "$work/last.log" ||
    bad "the box log does not name the data image change and the other changes"
grep -qF 'deploy the data image change alone' "$work/last.log" || bad "the box log does not say to deploy the data image change alone"
grep -q 'not deployed::' "$work/last.log" || bad "deploy-ssh.sh did not report exit 3"
record "J new monerod image and broken tor in one commit: refused (exit 3), nothing changed"

step "case J1: the same commit by hand with --allow-mixed-data: monerod starts on its new image, tor fails, no automatic rollback"
t0=$SECONDS
extra_env=(GATE_TIMEOUT=60)
deploy_ssh "$sha" "" --allow-mixed-data
want_rc 5
want_head "$sha"
grep -qF 'WARN  --allow-mixed-data: a service that keeps data gets a new image: monerod' "$work/last.log" ||
    bad "no warning for --allow-mixed-data"
grep -q "WARN  monerod keeps data in a volume, and its image changes from $monerod_image to $new_monerod" "$work/last.log" ||
    bad "no warning before the monerod image change"
grep -q "FAIL  monerod started on its new image $new_monerod at " "$work/last.log" ||
    bad "the box log does not say that monerod started on its new image"
grep -q 'FAIL  MANUAL ACTION NEEDED on' "$work/last.log" || bad "the box log does not say MANUAL ACTION NEEDED"
grep -q 'MANUAL ACTION NEEDED::' "$work/last.log" || bad "deploy-ssh.sh did not report MANUAL ACTION NEEDED"
! grep -q 'Roll back to' "$work/last.log" || bad "it rolled back after a new monerod image"
[[ $(docker inspect -f '{{.Config.Image}}' "$(docker compose ps -aq monerod)") == "$new_monerod" ]] ||
    bad "monerod does not run the new image"
j=$sha
record "J1 the same by hand with --allow-mixed-data: monerod started on its new image, tor failed: exit 5, no rollback"

step "case J2: from J1, a good change while tor still fails: no rollback"
t0=$SECONDS
sha=$(change_from "$j" "a prometheus.yml comment for case J2" sh -c 'printf "# case J2\n" >> monitoring/prometheus.yml')
extra_env=(GATE_TIMEOUT=60)
deploy deploy "$sha"
want_rc 0
want_head "$sha"
grep -q 'docker compose up --wait failed, but every service runs the config of' "$work/last.log" ||
    bad "no config check after the failed wait"
grep -q 'WARN  already failing before the change: tor has bootstrapped' "$work/last.log" ||
    bad "the summary does not call tor already failing"
! grep -q 'keeps data in a volume' "$work/last.log" || bad "a change with the same images got a data warning"
record "J2 from J1, a good change while tor fails: deployed (exit 0), the tor checks already failing"

step "case J3: deploy base again by hand with --allow-mixed-data: monerod gets its old image, tor works again"
t0=$SECONDS
local_runs() { find "$runs" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/local-[0-9]{10}' | wc -l; }
n_local=$(local_runs)
deploy_ssh "$base" "" --allow-mixed-data
want_rc 0
(($(local_runs) == n_local + 1)) || bad "the deploy by hand did not use a local-<unix time> run dir"
want_head "$base"
want_all_running
want_same_onion
grep -q 'PASS  tor has bootstrapped (it failed before the change)' "$work/last.log" || bad "the gate does not say that tor works again"
grep -q "WARN  monerod keeps data in a volume, and its image changes from $new_monerod to $monerod_image" "$work/last.log" ||
    bad "no warning before the monerod image change"
monerod_started=$(started monerod)
sha=$base
record "J3 back to base, by hand with --allow-mixed-data and no SSH_KEY: deployed (exit 0), tor works again, onion and key same"

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
((${#made[@]} == 3)) || bad "${#made[@]} rotating backups, expected 3 (BACKUP_KEEP=3)"
[[ -e $backups/tor-keys-2026-10-16.tgz ]] || bad "rotation removed the hand-made backup"
for f in "${made[@]}"; do
    [[ $(stat -c %a "$f") == 600 ]] || bad "$f has mode $(stat -c %a "$f")"
done
[[ $(tar -xzOf "${made[-1]}" ./monerod/hs_ed25519_secret_key | sha256sum | cut -d ' ' -f 1) == "$key" ]] ||
    bad "the newest backup does not hold the onion key"
results+=("PASS  backups: 3 kept (BACKUP_KEEP=3), mode 600, newest holds the key, hand-made backup kept")

step "cert-reload waits for the deploy lock"
lock=/var/lib/monero-node-deploy/lock
install -d -m 700 "${lock%/*}"
flock "$lock" sleep 6 &
holder=$!
sleep 1
t0=$SECONDS
bash "$root/scripts/cert-reload.sh" >/dev/null 2>&1 || true # no cert here, so it stops after the lock
waited=$((SECONDS - t0))
wait "$holder"
((waited >= 4)) || bad "cert-reload did not wait for the deploy lock (${waited}s)"
results+=("PASS  cert-reload waited ${waited}s for the deploy lock")
