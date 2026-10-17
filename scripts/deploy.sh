#!/usr/bin/env bash
# Deploys one commit of monero-node on this box, checks the result, and
# rolls back to the previous commit when any step or check fails.
#
# The deploy workflow runs it through scripts/deploy-ssh.sh. By hand, as root:
#   scripts/deploy.sh deploy --target <full sha> --domain eu.node.monero.one --onion <name>.onion
#   scripts/deploy.sh gate --onion <name>.onion
#
# Commands:
#   deploy  check out --target, start it, run the gate, roll back on failure
#   start   run deploy detached from this SSH session, follow its log, exit with its code
#   follow  follow a detached deploy again (after a dropped SSH session)
#   gate    run only the checks: containers, HTTP, tor, onion name and key
#   render  fill the ${DOMAIN} and ${TELEGRAM_CHAT_ID} templates in the checkout
#
# Exit codes of deploy, start and follow:
#   0  deployed, and the gate passed
#   1  failed, rolled back, and the previous commit passed the gate
#   2  failed, and the rollback failed too. The box needs a person now.
#   3  stopped before any change (lock, wrong box, onion key, backup, fetch, bad --run-dir)
#   4  (follow) no deploy started in --run-dir
#
# The tor-keys volume is only read, by a throwaway read-only container.
# Nothing here writes to it or removes it, not even in a rollback.
set -Eeuo pipefail
shopt -s inherit_errexit

REPO_DIR=$(readlink -f "${REPO_DIR:-/opt/monero-node}")
STATE_DIR=${STATE_DIR:-/var/lib/monero-node-deploy}
BACKUP_DIR=${BACKUP_DIR:-/root}
BACKUP_KEEP=${BACKUP_KEEP:-10}          # tor key backups to keep
RUNS_KEEP=${RUNS_KEEP:-20}              # run logs to keep
LOCK_WAIT=${LOCK_WAIT:-900}             # seconds to wait for a deploy that runs now
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600}       # seconds for each docker compose up --wait
GATE_TIMEOUT=${GATE_TIMEOUT:-300}       # seconds for all polling gate checks together
STABLE_SECONDS=${STABLE_SECONDS:-30}    # no container may restart in this window
HOST_SETUP=${HOST_SETUP:-1}             # 0 skips the cron file and the cert chmod (CI)
HTTP_HOST=${HTTP_HOST:-localhost}       # where the published ports answer
TOR_LOG_GRACE=${TOR_LOG_GRACE:-21600}   # tor up longer than this may have rotated out its bootstrap line

TOR_USER=104:107                        # owns the onion keys on the boxes
RUN_ID='^([0-9]+|local)-[0-9]+$'        # run dir names: <workflow run id>-<attempt>, or local-<n>
STATUS_OK='"status"[[:space:]]*:[[:space:]]*"OK"'
SELF=$(readlink -f "${BASH_SOURCE[0]}")

CMD="" TARGET="" DOMAIN="" ONION="" KEY_SHA256="" RUN_DIR=""
PREV="" BASE_KEY="" GATE_DEADLINE=0 ONION_SOCK=""
PROJECT="" TOR_IMAGE="" TOR_KEYS_VOLUME="" CERTS_VOLUME="" CERTBOT_IMAGE=""
SERVICES=() ARGS=()

# ---------------------------------------------------------------- output

ts() { date -u +%H:%M:%S; }
log() { printf '%s  %s\n' "$(ts)" "$*"; }
pass() { printf '%s  PASS  %s\n' "$(ts)" "$*"; }
fail() { printf '%s  FAIL  %s\n' "$(ts)" "$*"; }
warn() { printf '%s  WARN  %s\n' "$(ts)" "$*"; }
die() {
    local rc=$1
    shift
    fail "$*"
    exit "$rc"
}
# The ERR trap of a deploy phase. It names the function and the line that
# failed. For a function that returned non-zero, it shows the call line.
on_err() {
    local rc=$1 cmd=$2 line=${BASH_LINENO[0]} func=${FUNCNAME[1]:-main} src=""
    if [[ $cmd == return* ]]; then
        src=$(sed -n "${line}p" "$SELF" 2>/dev/null || true)
        src=${src#"${src%%[![:space:]]*}"}
    fi
    fail "step failed (exit $rc) in $func, line $line: ${src:-$cmd}"
}

# Deploy logs are public on GitHub. Mask IPs in any container output we
# print, and indent it, so no line can start a workflow command.
quote_log() {
    sed -E -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g' \
        -e 's/([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}/x:x::x/g' \
        -e 's/^/    | /'
}

usage() {
    sed -n '2,/^set -E/p' "$SELF" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- arguments

parse_args() {
    while (($#)); do
        case $1 in
            --target) TARGET=${2:-} ;;
            --domain) DOMAIN=${2:-} ;;
            --onion) ONION=${2:-} ;;
            --key-sha256) KEY_SHA256=${2:-} ;;
            --run-dir) RUN_DIR=${2:-} ;;
            -h | --help) usage ;;
            *) die 3 "unknown argument: $1" ;;
        esac
        (($# >= 2)) || die 3 "$1 needs a value"
        shift 2
    done
}

need_target() { [[ $TARGET =~ ^[0-9a-f]{40}$ ]] || die 3 "--target must be a full 40 character commit sha"; }
need_domain() { [[ $DOMAIN =~ ^[a-z0-9.-]+$ ]] || die 3 "--domain is missing or not a host name"; }
need_onion() { [[ $ONION =~ ^[a-z2-7]{56}\.onion$ ]] || die 3 "--onion is missing or not a v3 onion name"; }
# --run-dir must be $STATE_DIR/runs/<run id>, as deploy-ssh.sh makes it, with
# no symlink, no "." and no ".." in it. prune_runs deletes the old dirs next
# to it, so any other path could delete dirs that are not runs.
need_run_dir() {
    local runs real
    runs=$(realpath -m "$STATE_DIR/runs")
    real=$(realpath -m -- "$RUN_DIR" 2>/dev/null) || real=""
    if [[ -z $RUN_DIR || $RUN_DIR != "$real" || ${real%/*} != "$runs" || ! ${real##*/} =~ $RUN_ID ]]; then
        die 3 "--run-dir must be $runs/<run id> (like 1234-1 or local-1), with no symlink in it"
    fi
}

# ---------------------------------------------------------------- compose

# Ids of the service containers of this project (no one-off containers)
project_ids() {
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.oneoff=False"
}

# Container id of a service, empty when it has none
cid() {
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.oneoff=False" \
        --filter "label=com.docker.compose.service=$1" | head -n 1
}

# "<service> <container id>" for each service container
service_ids() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.oneoff=False" \
        --format '{{.Label "com.docker.compose.service"}} {{.ID}}'
}

# Facts from the compose file in the checkout. The JSON holds secrets from
# .env, so it only goes into python, never to the log.
load_compose_facts() {
    local out services
    out=$(docker compose config --format json | python3 -c '
import json, sys
c = json.load(sys.stdin)
print(c["name"])
print(c["services"]["tor"]["image"])
print(c["volumes"]["tor-keys"]["name"])
print(c["volumes"]["certbot-conf"]["name"])
print(c["services"]["certbot"]["image"])
') || { fail "cannot read the compose file"; return 1; }
    { read -r PROJECT; read -r TOR_IMAGE; read -r TOR_KEYS_VOLUME; read -r CERTS_VOLUME; read -r CERTBOT_IMAGE; } <<<"$out"
    if [[ -z $PROJECT || -z $TOR_IMAGE || -z $TOR_KEYS_VOLUME || -z $CERTS_VOLUME || -z $CERTBOT_IMAGE ]]; then
        fail "the compose file has no tor, certbot, tor-keys or certbot-conf"
        return 1
    fi
    services=$(docker compose config --services) || { fail "cannot list the compose services"; return 1; }
    mapfile -t SERVICES <<<"$services"
}

# A KEY=VALUE line from .env, read without running the file
env_value() {
    local line
    line=$(grep -E "^$1=" .env | tail -n 1 || true)
    line=${line#*=}
    line=${line%$'\r'}
    if [[ $line =~ ^\"(.*)\"$ || $line =~ ^\'(.*)\'$ ]]; then
        line=${BASH_REMATCH[1]}
    fi
    printf '%s' "$line"
}

# ---------------------------------------------------------------- onion keys

# Runs a shell snippet in a throwaway container that sees the tor-keys
# volume read-only, as the uid that owns the keys, with no network.
with_keys_ro() {
    docker run --rm --pull never --network none --user "$TOR_USER" --cap-drop ALL \
        --security-opt no-new-privileges --read-only \
        --volume "$TOR_KEYS_VOLUME:/keys:ro" --entrypoint sh "$TOR_IMAGE" -c "$1"
}

# "<hostname> <sha256 of the secret key> <uid:gid> <mode>" of monerod/ in the volume
volume_key_state() {
    # shellcheck disable=SC2016 # the container shell expands these
    with_keys_ro 'd=/keys/monerod
        h=$(cat "$d/hostname") &&
        k=$(sha256sum < "$d/hs_ed25519_secret_key" | cut -d " " -f 1) &&
        o=$(stat -c "%u:%g %a" "$d") &&
        printf "%s %s %s\n" "$h" "$k" "$o"'
}

# Called as "backup_tor_keys || die", so every step checks its own status
backup_tor_keys() {
    local stamp file got
    local -a all
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    file="$BACKUP_DIR/tor-keys-$stamp.tgz"
    (
        umask 077
        with_keys_ro 'tar --numeric-owner -C /keys -czf - .' >"$file.partial"
    ) || {
        rm -f "$file.partial"
        return 1
    }
    chmod 600 "$file.partial" || return 1
    # The archive must hold the key that tor uses now
    got=$(tar -xzOf "$file.partial" ./monerod/hs_ed25519_secret_key | sha256sum | cut -d ' ' -f 1) || got=""
    if [[ $got != "$BASE_KEY" ]]; then
        rm -f "$file.partial"
        fail "the backup does not hold the current onion key"
        return 1
    fi
    mv "$file.partial" "$file" || return 1
    pass "onion keys backed up to $file (mode 600)"
    # Keep the newest BACKUP_KEEP of these. Other files, like manual backups, stay.
    shopt -s nullglob
    all=("$BACKUP_DIR"/tor-keys-????????T??????Z.tgz)
    shopt -u nullglob
    if ((${#all[@]} > BACKUP_KEEP)); then
        rm -f -- "${all[@]:0:${#all[@]}-BACKUP_KEEP}" || return 1
    fi
}

# ---------------------------------------------------------------- checkout

render_templates() {
    local chat cp=monitoring/grafana/provisioning/alerting/contactpoints.yml
    if [[ -f nginx.conf ]]; then
        sed -i "s/\${DOMAIN}/$DOMAIN/g" nginx.conf
    fi
    if [[ -f $cp ]]; then
        chat=$(env_value TELEGRAM_CHAT_ID)
        if [[ $chat =~ ^-?[0-9]+$ ]]; then
            sed -i "s/\${TELEGRAM_CHAT_ID}/$chat/g" "$cp"
        else
            warn "TELEGRAM_CHAT_ID in .env is not a number, so Grafana alerts cannot reach Telegram"
        fi
    fi
}

host_setup() {
    ((HOST_SETUP)) || return 0
    # monerod runs as non-root and must read the Let's Encrypt key
    if ! docker run --rm --pull never --entrypoint sh -v "$CERTS_VOLUME:/etc/letsencrypt" "$CERTBOT_IMAGE" \
        -c 'chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive && chmod -R a+rX /etc/letsencrypt/live/ /etc/letsencrypt/archive/' \
        >/dev/null 2>&1; then
        warn "could not fix the cert permissions in $CERTS_VOLUME"
    fi
    # A deploy restarts monerod only when it changed. This daily cron
    # restarts it after a cert renewal, because monerod never re-reads it.
    if [[ -f scripts/cert-reload.sh ]]; then
        install -m 755 scripts/cert-reload.sh /etc/cron.daily/monerod-cert-reload
    fi
    # Container state metrics for the Grafana container alerts
    if [[ -f scripts/docker-metrics.cron ]]; then
        install -d -m 755 /var/lib/node-exporter/textfile
        install -m 644 scripts/docker-metrics.cron /etc/cron.d/monero-node-docker-metrics
    fi
}

# Content hash of a file, or of all files in a directory
fingerprint() {
    if [[ -d $1 ]]; then
        (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d ' ' -f 1
    elif [[ -e $1 ]]; then
        sha256sum <"$1" | cut -d ' ' -f 1
    else
        echo missing
    fi
}

# "<service> <path>" for each bind mount from the checkout. A running
# container keeps the old file after git replaces it, and compose does not
# recreate a service when only a file that it mounts changed.
repo_binds() {
    local svc paths p
    local -a ids
    mapfile -t ids < <(project_ids)
    ((${#ids[@]})) || return 0
    docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}{{range .Mounts}}{{if eq .Type "bind"}} {{.Source}}{{end}}{{end}}' "${ids[@]}" |
        while read -r svc paths; do
            for p in $paths; do
                if [[ $p == "$REPO_DIR"/* ]]; then
                    printf '%s %s\n' "$svc" "$p"
                fi
            done
        done
}

# Moves the checkout and the stack to a commit. A container keeps the old
# copy of a file it mounts from the checkout, even after git replaces it.
# So the services whose mounted files changed are recreated first. Then
# plain "up" recreates the services whose compose definition changed, and
# waits for all of them. Nothing else restarts, so a deploy that does not
# touch monerod leaves it running.
switch_to() {
    local commit=$1 svc path id key
    local -A fp_before=() id_before=() id_after=() stale=() known=()

    while read -r svc path; do fp_before["$svc $path"]=$(fingerprint "$path"); done < <(repo_binds)
    while read -r svc id; do id_before[$svc]=$id; done < <(service_ids)

    log "check out $commit"
    git reset -q --hard "$commit"
    [[ $(git rev-parse HEAD) == "$commit" ]]
    render_templates
    load_compose_facts
    docker compose config -q

    log "pull the images that are not on this box"
    docker compose pull --policy missing --quiet
    host_setup

    for svc in "${SERVICES[@]}"; do known[$svc]=1; done
    for key in "${!fp_before[@]}"; do
        svc=${key%% *} path=${key#* }
        [[ -n ${known[$svc]:-} ]] || continue
        [[ $(fingerprint "$path") == "${fp_before[$key]}" ]] || stale[$svc]=1
    done
    if ((${#stale[@]})); then
        log "recreate, a mounted file changed: ${!stale[*]}"
        docker compose up -d --no-deps --force-recreate "${!stale[@]}"
    fi

    log "docker compose up --wait (up to ${WAIT_TIMEOUT}s)"
    docker compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"

    while read -r svc id; do id_after[$svc]=$id; done < <(service_ids)
    for svc in "${SERVICES[@]}"; do
        if [[ ${id_after[$svc]:-} != "${id_before[$svc]:-}" ]]; then
            log "  recreated: $svc"
        fi
    done
}

# ---------------------------------------------------------------- gate

# State and last log lines of a container, for the job log
explain() {
    [[ -n $1 ]] || return 0
    docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} error={{.State.Error}}' "$1" 2>&1 | quote_log || true
    docker logs --tail 15 "$1" 2>&1 | quote_log || true
}

# poll <what> <command...>: retry every 5 s until it passes or the gate time runs out
poll() {
    local what=$1
    shift
    until "$@"; do
        if ((SECONDS >= GATE_DEADLINE)); then
            fail "$what"
            return 1
        fi
        sleep 5
    done
    pass "$what"
}

# Every service has a running container, healthy where it has a healthcheck
check_containers() {
    local svc id state health restarts
    local -a pending
    while :; do
        pending=()
        for svc in "${SERVICES[@]}"; do
            id=$(cid "$svc")
            if [[ -z $id ]]; then
                fail "$svc has no container"
                return 1
            fi
            read -r state health restarts < <(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$id")
            case $state/$health in
                running/none | running/healthy) ;;
                created/* | dead/*)
                    fail "$svc is $state"
                    explain "$id"
                    return 1
                    ;;
                *)
                    # A crash loop does not heal. Stop the wait early.
                    if [[ $state != running ]] && ((restarts >= 3)); then
                        fail "$svc crash-loops ($restarts restarts)"
                        explain "$id"
                        return 1
                    fi
                    pending+=("$svc")
                    ;;
            esac
        done
        if ((${#pending[@]} == 0)); then
            pass "all ${#SERVICES[@]} services run, healthy where they have a healthcheck"
            return 0
        fi
        if ((SECONDS >= GATE_DEADLINE)); then
            for svc in "${pending[@]}"; do
                fail "$svc is not running and healthy"
                explain "$(cid "$svc")"
            done
            return 1
        fi
        sleep 5
    done
}

# Lines of "<service> <id> <status> <start time> <restarts>"
snapshot() {
    local -a ids
    mapfile -t ids < <(project_ids)
    ((${#ids[@]})) || return 0
    docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}} {{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.RestartCount}}' "${ids[@]}" | sort
}

# http_ok <url> <regex>: the body must match
http_ok() {
    local body
    body=$(curl -sk --max-time 10 "$1" 2>/dev/null) || return 1
    [[ $body =~ $2 ]]
}

# exec_ok <service> <url> [curl options]: curl in that container must get status OK
exec_ok() {
    local svc=$1 url=$2 id body
    shift 2
    id=$(cid "$svc")
    [[ -n $id ]] || return 1
    body=$(docker exec "$id" curl -sk --max-time 20 "$@" "$url" 2>/dev/null) || return 1
    [[ $body =~ $STATUS_OK ]]
}

# The tor in a service logged "Bootstrapped 100%" since its last start
tor_bootstrapped() {
    local id started logs age
    id=$(cid "$1")
    [[ -n $id ]] || return 1
    started=$(docker inspect -f '{{.State.StartedAt}}' "$id") || return 1
    logs=$(docker logs --since "$started" "$id" 2>&1) || return 1
    [[ $logs != *"Bootstrapped 100%"* ]] || return 0
    # Its 1 MB log may have dropped the line after a long run
    age=$(($(date +%s) - $(date -d "$started" +%s)))
    if ((age > TOR_LOG_GRACE)); then
        warn "$1 runs for ${age}s, and its log no longer shows the bootstrap"
        return 0
    fi
    return 1
}

flag_value() { awk -v f="$1" 'p { print; exit } $0 == f { p = 1 }'; }

# tor serves the pinned onion name, with the key from before the deploy
check_onion() {
    local id args dir port out host key
    id=$(cid tor)
    if [[ -z $id ]]; then
        fail "tor has no container"
        return 1
    fi
    args=$(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$id")
    dir=$(flag_value --HiddenServiceDir <<<"$args")
    port=$(flag_value --HiddenServicePort <<<"$args")
    if [[ -z $dir || $port != *unix:* ]]; then
        fail "tor has no --HiddenServiceDir flag or no unix socket --HiddenServicePort"
        return 1
    fi
    ONION_SOCK=${port##*unix:}
    # shellcheck disable=SC2016 # the container shell expands these
    if ! out=$(docker exec "$id" sh -c 'cat "$1/hostname" && sha256sum < "$1/hs_ed25519_secret_key" | cut -d " " -f 1' sh "$dir" 2>/dev/null); then
        fail "tor has no onion key in $dir"
        return 1
    fi
    { read -r host; read -r key; } <<<"$out"
    if [[ $host != "$ONION" ]]; then
        fail "tor serves $host, but the pinned onion is $ONION"
        return 1
    fi
    if [[ $key != "$BASE_KEY" ]]; then
        fail "tor serves $ONION, but with a key that differs from before the deploy"
        return 1
    fi
    pass "tor serves $ONION with the same key as before the deploy"
}

gate() {
    local t0 rest before after svc
    local -a changed
    GATE_DEADLINE=$((SECONDS + GATE_TIMEOUT))
    log "gate: checks for up to ${GATE_TIMEOUT}s"
    check_containers
    before=$(snapshot)
    t0=$SECONDS
    poll "http://$HTTP_HOST/health answers status OK" http_ok "http://$HTTP_HOST/health" "$STATUS_OK"
    poll "RPC on port 443 answers status OK" http_ok "https://$HTTP_HOST:443/get_height" "$STATUS_OK"
    poll "RPC on port 18089 answers status OK" http_ok "https://$HTTP_HOST:18089/get_height" "$STATUS_OK"
    poll "Grafana answers, database ok" http_ok "http://$HTTP_HOST/grafana/api/health" '"database"[[:space:]]*:[[:space:]]*"ok"'
    poll "monerod-rpc-proxy reaches monerod" exec_ok monerod-rpc-proxy http://localhost:18081/get_height
    poll "tor has bootstrapped" tor_bootstrapped tor
    poll "tor-client has bootstrapped" tor_bootstrapped tor-client
    check_onion
    poll "the onion socket exists in tor" docker exec "$(cid tor)" test -S "$ONION_SOCK"
    poll "the onion socket answers plain HTTP" exec_ok onion-proxy http://localhost/get_height --unix-socket "$ONION_SOCK"
    poll "the onion socket answers TLS" exec_ok onion-proxy https://localhost/get_height --unix-socket "$ONION_SOCK"

    rest=$((STABLE_SECONDS - (SECONDS - t0)))
    if ((rest > 0)); then
        sleep "$rest"
    fi
    after=$(snapshot)
    if [[ $after != "$before" ]]; then
        mapfile -t changed < <({ diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true; } | awk '/^[<>]/ { print $2 }' | sort -u)
        for svc in "${changed[@]}"; do
            fail "$svc restarted during the gate"
            explain "$(cid "$svc")"
        done
        return 1
    fi
    pass "no container restarted in $((SECONDS - t0))s"
}

# ---------------------------------------------------------------- commands

preflight() {
    local env_domain avail dir host key owner mode state
    cd "$REPO_DIR" 2>/dev/null || die 3 "no checkout at $REPO_DIR"
    install -d -m 700 "$STATE_DIR" "$BACKUP_DIR"
    exec 9>"$STATE_DIR/lock"
    if ! flock -n 9; then
        log "another deploy runs on this box, wait up to ${LOCK_WAIT}s"
        flock -w "$LOCK_WAIT" 9 || die 3 "another deploy still runs on this box"
    fi
    command -v python3 >/dev/null || die 3 "python3 is missing"
    [[ -d .git && -f .env ]] || die 3 "$REPO_DIR has no .git or no .env"
    env_domain=$(env_value DOMAIN)
    [[ $env_domain == "$DOMAIN" ]] || die 3 "this box is ${env_domain:-unknown}, but the deploy is for $DOMAIN"
    docker info >/dev/null 2>&1 || die 3 "docker does not answer"
    log "$(docker compose version)"
    for dir in "$REPO_DIR" "$BACKUP_DIR" "$STATE_DIR"; do
        avail=$(df -Pk "$dir" | awk 'NR == 2 { print $4 }')
        ((${avail:-0} > 1048576)) || die 3 "less than 1 GiB is free for $dir"
    done

    PREV=$(git rev-parse HEAD)
    git fetch -q origin || die 3 "git fetch failed"
    git cat-file -e "$TARGET^{commit}" 2>/dev/null || die 3 "commit $TARGET is not in origin"
    git merge-base --is-ancestor "$TARGET" origin/main || die 3 "commit $TARGET is not on origin/main"

    load_compose_facts || die 3 "docker compose config failed for $PREV"
    state=$(volume_key_state 2>/dev/null) || die 3 "cannot read the onion key in volume $TOR_KEYS_VOLUME"
    read -r host key owner mode <<<"$state"
    [[ $host == "$ONION" ]] || die 3 "the onion key on this box is for ${host:-nothing}, but the pinned onion is $ONION"
    [[ $key =~ ^[0-9a-f]{64}$ ]] || die 3 "cannot hash the onion key"
    BASE_KEY=$key
    pass "the onion key on this box is for $ONION"
    if [[ "$owner $mode" != "$TOR_USER 700" ]]; then
        warn "the onion key dir is $owner mode $mode, expected $TOR_USER mode 700"
    fi
    backup_tor_keys || die 3 "the onion key backup failed"
}

cmd_deploy() {
    local rc
    need_target
    need_domain
    need_onion
    if [[ -n $RUN_DIR ]]; then
        need_run_dir
        echo "$$" >"$RUN_DIR/pid"
        trap 'echo "$?" >"$RUN_DIR/status.tmp" && mv "$RUN_DIR/status.tmp" "$RUN_DIR/status"' EXIT
    fi
    preflight
    log "deploy $TARGET to $DOMAIN (the box runs $PREV)"

    set +e
    (
        set -e
        trap 'on_err $? "$BASH_COMMAND"' ERR
        switch_to "$TARGET"
        gate
    )
    rc=$?
    set -e
    if ((rc == 0)); then
        pass "deployed $TARGET to $DOMAIN"
        exit 0
    fi

    fail "the deploy of $TARGET failed. Roll back to $PREV"
    set +e
    (
        set -e
        trap 'on_err $? "$BASH_COMMAND"' ERR
        switch_to "$PREV"
        gate
    )
    rc=$?
    set -e
    if ((rc == 0)); then
        fail "rolled back to $PREV, and it passed the gate. $TARGET is not deployed."
        exit 1
    fi
    fail "THE ROLLBACK FAILED. $DOMAIN runs a broken stack and needs a person now."
    exit 2
}

cmd_start() {
    need_run_dir
    install -d -m 700 "$RUN_DIR"
    [[ ! -e $RUN_DIR/pid ]] || die 3 "a deploy already started in $RUN_DIR. Use follow."
    setsid nohup bash "$SELF" deploy "${ARGS[@]}" >"$RUN_DIR/log" 2>&1 </dev/null &
    prune_runs
    cmd_follow
}

cmd_follow() {
    local i pid
    need_run_dir
    for ((i = 0; i < 30; i++)); do
        [[ -s $RUN_DIR/pid ]] && break
        sleep 1
    done
    [[ -s $RUN_DIR/pid ]] || die 4 "no deploy started in $RUN_DIR"
    pid=$(<"$RUN_DIR/pid")
    tail -n +1 -f --pid "$pid" "$RUN_DIR/log"
    for ((i = 0; i < 10; i++)); do
        [[ -s $RUN_DIR/status ]] && break
        sleep 1
    done
    [[ -s $RUN_DIR/status ]] || die 2 "the deploy stopped with no result. See $RUN_DIR/log"
    exit "$(<"$RUN_DIR/status")"
}

# Keeps this run dir and the newest RUNS_KEEP - 1 others. need_run_dir
# checked that RUN_DIR is in $STATE_DIR/runs. Only dirs there with a run id
# name can go. "find -type d" skips symlinks.
prune_runs() {
    local dir
    local -a old=()
    while IFS= read -r dir; do
        if [[ $dir != "$RUN_DIR" && ${dir##*/} =~ $RUN_ID ]]; then
            old+=("$dir")
        fi
    done < <(find "${RUN_DIR%/*}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d ' ' -f 2-)
    if ((${#old[@]} >= RUNS_KEEP)); then
        rm -rf -- "${old[@]:RUNS_KEEP-1}"
    fi
}

cmd_gate() {
    local state
    need_onion
    cd "$REPO_DIR"
    load_compose_facts
    if [[ -n $KEY_SHA256 ]]; then
        BASE_KEY=$KEY_SHA256
    else
        state=$(volume_key_state)
        read -r _ BASE_KEY _ <<<"$state"
    fi
    gate
}

cmd_render() {
    need_domain
    cd "$REPO_DIR"
    render_templates
}

main() {
    (($#)) || usage
    CMD=$1
    shift
    ARGS=("$@")
    parse_args "$@"
    case $CMD in
        deploy) cmd_deploy ;;
        start) cmd_start ;;
        follow) cmd_follow ;;
        gate) cmd_gate ;;
        render) cmd_render ;;
        -h | --help | help) usage ;;
        *) die 3 "unknown command: $CMD" ;;
    esac
}

main "$@"
