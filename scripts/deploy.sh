#!/usr/bin/env bash
# Deploys one commit of monero-node on this box, checks the result, and
# rolls back to the previous commit when the deploy fails a step or breaks
# a check that passed before it.
#
# The deploy workflow runs it through scripts/deploy-ssh.sh. To deploy by
# hand the same way, from a checkout with root SSH access to the box, run
# this for EU, and for US only after a good EU deploy (the onion names are
# in .github/workflows/deploy.yml):
#   scripts/deploy-ssh.sh eu.node.monero.one eu.node.monero.one <EU onion> "$(git rev-parse origin/main)"
# On the box itself, as root:
#   scripts/deploy.sh deploy --target <full sha> --domain eu.node.monero.one --onion <name>.onion
#   scripts/deploy.sh gate --onion <name>.onion
#
# Commands:
#   deploy  run the gate, check out --target and start it, run the gate again,
#           and roll back when a check fails that passed before the change
#   start   run deploy detached from this SSH session, follow its log, exit with its code
#   follow  follow a detached deploy again (after a dropped SSH session)
#   gate    run only the checks: containers, HTTP, chain height, tor, onion
#           name and key. Exit 0 when all pass, 1 at the first failure.
#   render  fill the ${DOMAIN} and ${TELEGRAM_CHAT_ID} templates in the checkout
#
# Options: --target <full sha>, --domain <box name>, --onion <name>.onion,
# --run-dir <dir> (start, follow), and --key-sha256 <hex> (deploy, gate): the
# sha256 of the onion secret key that the box must have.
#
# Exit codes of deploy, start and follow:
#   0  deployed, and no check regressed. The log lists the checks that
#      failed before the change and still fail ("already failing").
#   1  a step failed or a check regressed, so it rolled back. After the
#      rollback, every check passed that passed before the change.
#   2  failed, and the rollback failed too. The box needs a person now.
#   3  stopped before any change (lock, wrong box, onion key, backup, fetch, bad --run-dir)
#   4  (follow) no deploy started in --run-dir
#   5  MANUAL ACTION NEEDED. It failed after a new image for a service that
#      keeps data in a volume, like monerod. The old image could fail on
#      data that the new image migrated, so there was no automatic
#      rollback. The box stays on --target.
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
PRE_GATE_TIMEOUT=${PRE_GATE_TIMEOUT:-60} # the same for the gate before the change
STABLE_SECONDS=${STABLE_SECONDS:-30}    # no container may restart in this window
HOST_SETUP=${HOST_SETUP:-1}             # 0 skips the cron file and the cert chmod (CI)
HTTP_HOST=${HTTP_HOST:-localhost}       # where the published ports answer
TOR_LOG_GRACE=${TOR_LOG_GRACE:-21600}   # tor up longer than this may have rotated out its bootstrap line

TOR_USER=104:107                        # owns the onion keys on the boxes
RUN_ID='^([0-9]+|local)-[0-9]+$'        # run dir names: <workflow run id>-<attempt>, or local-<n>
STATUS_OK='"status"[[:space:]]*:[[:space:]]*"OK"'
KNOWN="already failing before the change"
# Files that only the box has. No deployed commit may track them.
BOX_FILES=(.env aws docker-compose.override.yml tor-keys)
# Volumes that no image migrates, so a rollback is safe with them: tor
# reads its keys as they are, onion-sock holds only a socket, and
# certbot-www holds only ACME challenge files.
ROLLBACK_SAFE_VOLUMES=(tor-keys onion-sock certbot-www)
# Not a file when bash reads this script from stdin ("bash -s -- gate ...")
SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}" || true)

CMD="" TARGET="" DOMAIN="" ONION="" KEY_SHA256="" RUN_DIR="" COMPOSE_VERSION=""
PREV="" BASE_KEY="" PROJECT="" TOR_IMAGE="" TOR_KEYS_VOLUME="" CERTS_VOLUME="" CERTBOT_IMAGE=""
GATE_MODE=post GATE_PASS=1 GATE_DEADLINE=0 GATE_DIR="" GATE_FILE="" PRE_HEIGHT="" PHASE_RC=0
SERVICES=() ARGS=()
declare -A PRE=()                       # check id -> its result before the change: pass, fail or wrong

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

# Deploy logs are public on GitHub. quote_log hides secrets and IPs in the
# container output that a deploy prints: each value in .env (4 or more
# characters), Telegram bot tokens (also the "bot<token>" form in URLs),
# and IPv4 and IPv6 addresses. It also indents each line, so no line can
# start a workflow command.
quote_log() {
    python3 -c '
import re, sys

secrets = []
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as env:
        for line in env:
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            if line.startswith("#") or "=" not in line:
                continue
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"\x27":
                value = value[1:-1]
            if len(value) >= 4:
                secrets.append(value)
except OSError:
    pass
secrets.sort(key=len, reverse=True)
masks = [
    (re.compile(r"[0-9]{6,12}:[A-Za-z0-9_-]{30,}"), "[bot token]"),
    (re.compile(r"([0-9]{1,3}\.){3}[0-9]{1,3}"), "x.x.x.x"),
    (re.compile(r"([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}"), "x:x::x"),
]
for raw in sys.stdin.buffer:
    line = raw.decode("utf-8", "replace").rstrip("\r\n")
    for secret in secrets:
        line = line.replace(secret, "[secret]")
    for pattern, mask in masks:
        line = pattern.sub(mask, line)
    sys.stdout.write("    | " + line + "\n")
' "$REPO_DIR/.env"
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
# --key-sha256 is optional: the sha256 of hs_ed25519_secret_key that the box must have
check_key_sha256() { [[ -z $KEY_SHA256 || $KEY_SHA256 =~ ^[0-9a-f]{64}$ ]] || die 3 "--key-sha256 must be 64 hex characters"; }
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

# "<service> <image> <1 when it keeps data>" for each service. A service
# keeps data when it mounts a named volume read-write that is not in
# ROLLBACK_SAFE_VOLUMES.
service_images() {
    docker compose config --format json | python3 -c '
import json, sys
safe = set(sys.argv[1:])
c = json.load(sys.stdin)
for name, svc in sorted(c["services"].items()):
    data = any(v.get("type") == "volume" and v.get("source") not in safe and not v.get("read_only")
               for v in svc.get("volumes") or [])
    print(name, svc.get("image") or "-", int(data))
' "${ROLLBACK_SAFE_VOLUMES[@]}"
}

# mark_stateful <service images before the checkout>: writes each service
# that keeps data and gets another image to $GATE_DIR/stateful. It runs
# before the first container changes. After it, a failed deploy gets no
# automatic rollback, because the new image may migrate the data.
mark_stateful() {
    local now svc image data old new
    local -A was_image=() was_data=()
    now=$(service_images)
    while read -r svc image data; do
        [[ -n $svc ]] || continue
        was_image[$svc]=$image
        was_data[$svc]=$data
    done <<<"$1"
    : >"$GATE_DIR/stateful"
    while read -r svc image data; do
        [[ -n $svc && -n ${was_image[$svc]:-} && ${was_image[$svc]} != "$image" ]] || continue
        if [[ $data == 1 || ${was_data[$svc]} == 1 ]]; then
            printf '%s %s %s\n' "$svc" "${was_image[$svc]}" "$image" >>"$GATE_DIR/stateful"
        fi
    done <<<"$now"
    while read -r svc old new; do
        warn "$svc keeps data in a volume, and its image changes from $old to $new. From here on, a failure gets no automatic rollback."
    done <"$GATE_DIR/stateful"
}

# Every service has a container with the compose config of the checkout
config_applied() {
    local hashes svc hash id label rc=0
    hashes=$(docker compose config --hash '*') || return 1
    [[ -n $hashes ]] || return 1
    while read -r svc hash; do
        id=$(cid "$svc")
        label=""
        if [[ -n $id ]]; then
            label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$id") || label=""
        fi
        if [[ $label != "$hash" ]]; then
            fail "$svc does not run the config of the checkout"
            rc=1
        fi
    done <<<"$hashes"
    return "$rc"
}

# Moves the checkout and the stack to a commit. A container keeps the old
# copy of a file it mounts from the checkout, even after git replaces it.
# So the services whose mounted files changed are recreated first. Then
# plain "up" recreates the services whose compose definition changed, and
# waits for all of them. Nothing else restarts, so a deploy that does not
# touch monerod leaves it running.
# switch_to <commit> [forward]: forward also marks a new image for a service
# that keeps data (see mark_stateful). A rollback does not.
switch_to() {
    local commit=$1 mode=${2:-} svc path id key images=""
    local -A fp_before=() id_before=() id_after=() stale=() known=()

    while read -r svc path; do fp_before["$svc $path"]=$(fingerprint "$path"); done < <(repo_binds)
    while read -r svc id; do id_before[$svc]=$id; done < <(service_ids)
    if [[ $mode == forward ]]; then
        images=$(service_images)
    fi

    log "check out $commit"
    git reset -q --hard "$commit"
    [[ $(git rev-parse HEAD) == "$commit" ]]
    render_templates
    load_compose_facts
    docker compose config -q

    log "pull the images that are not on this box"
    docker compose pull --policy missing --quiet
    host_setup
    if [[ $mode == forward ]]; then
        mark_stateful "$images"
    fi

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
    if ! docker compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
        # A service that failed before the change fails this wait too. When
        # every service runs the new config, the gate decides.
        if ! config_applied; then
            fail "docker compose up stopped before every service ran the config of $commit"
            return 1
        fi
        warn "docker compose up --wait failed, but every service runs the config of $commit. The gate decides."
    fi

    while read -r svc id; do id_after[$svc]=$id; done < <(service_ids)
    for svc in "${SERVICES[@]}"; do
        if [[ ${id_after[$svc]:-} != "${id_before[$svc]:-}" ]]; then
            log "  recreated: $svc"
        fi
    done
}

# ---------------------------------------------------------------- gate
#
# A deploy runs the gate twice: before the change ("pre") and after it
# ("post"). The pre gate changes nothing. Each check records its result:
# pass, fail, or "wrong" when tor serves another onion. After the change, a
# check that fails and did not fail before is a regression, and only a
# regression makes the deploy roll back. A check with no result from before
# counts as one that passed. A check that failed before and still fails is
# "already failing": the deploy may be the fix for it, so it causes no
# rollback. A post gate stops at the first regression.
#
# Pass 1 runs the checks that did not fail before. Pass 2 then runs the
# others, so a check that already fails cannot use up the time of the rest.

# State and last log lines of a container, for the job log
explain() {
    [[ -n $1 ]] || return 0
    docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} error={{.State.Error}}' "$1" 2>&1 | quote_log || true
    docker logs --tail 15 "$1" 2>&1 | quote_log || true
}

# gate_turn <id>: the check runs in this pass of the gate
gate_turn() {
    [[ $GATE_MODE == post ]] || return 0
    if [[ ${PRE[$1]:-pass} == pass ]]; then ((GATE_PASS == 1)); else ((GATE_PASS == 2)); fi
}

# is_regression <id> <result>: for a check that fails now. tor that serves
# another onion is a regression, unless it did so before the change too.
is_regression() {
    local pre=${PRE[$1]:-pass}
    [[ $pre == pass || ($2 == wrong && $pre != wrong) ]]
}

# record [-q] <id> <result> <text>: adds the result to $GATE_FILE and prints
# it (-q: no PASS line). In a post gate, a regression ends the gate: record
# exits the deploy phase, or the gate command, with 1.
record() {
    local quiet=0
    if [[ $1 == -q ]]; then
        quiet=1
        shift
    fi
    local id=$1 result=$2 text=$3
    if [[ -n $GATE_FILE ]]; then
        printf '%s\t%s\t%s\n' "$id" "$result" "$text" >>"$GATE_FILE"
    fi
    if [[ $result == pass ]]; then
        if [[ $GATE_MODE == post && ${PRE[$id]:-pass} != pass ]]; then
            pass "$text (it failed before the change)"
        elif ((quiet == 0)); then
            pass "$text"
        fi
    elif [[ $GATE_MODE == pre ]]; then
        warn "fails before the change: $text"
    elif is_regression "$id" "$result"; then
        fail "$text"
        exit 1
    else
        fail "$text ($KNOWN)"
    fi
}

# check <id> <text> <command...>: retries the command every 5 s until it
# passes or the gate time runs out, and records the result
check() {
    local id=$1 what=$2
    shift 2
    gate_turn "$id" || return 0
    until "$@"; do
        if ((SECONDS >= GATE_DEADLINE)); then
            record "$id" fail "$what"
            return 0
        fi
        sleep 5
    done
    record "$id" pass "$what"
}

# Every service of this pass has a running container, healthy where it has
# a healthcheck. A container that is created or dead, or in a crash loop,
# fails at once. The others get until the end of the gate time.
check_containers() {
    local svc id state health restarts n bad=0
    local -a todo=() left
    for svc in "${SERVICES[@]}"; do
        if gate_turn "svc:$svc"; then todo+=("$svc"); fi
    done
    n=${#todo[@]}
    ((n)) || return 0
    while :; do
        left=()
        for svc in "${todo[@]}"; do
            id=$(cid "$svc")
            state=missing health=none restarts=0
            if [[ -n $id ]]; then
                read -r state health restarts < <(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$id" 2>/dev/null || echo missing none 0)
            fi
            case $state/$health in
                running/none | running/healthy) record -q "svc:$svc" pass "$svc runs" ;;
                missing/*)
                    bad=$((bad + 1))
                    record "svc:$svc" fail "$svc has no container"
                    ;;
                created/* | dead/*)
                    bad=$((bad + 1))
                    explain "$id"
                    record "svc:$svc" fail "$svc is $state"
                    ;;
                *)
                    # A crash loop does not heal. Stop the wait early.
                    if [[ $state != running ]] && ((restarts >= 3)); then
                        bad=$((bad + 1))
                        explain "$id"
                        record "svc:$svc" fail "$svc crash-loops ($restarts restarts)"
                    else
                        left+=("$svc")
                    fi
                    ;;
            esac
        done
        ((${#left[@]})) || break
        if ((SECONDS >= GATE_DEADLINE)); then
            for svc in "${left[@]}"; do
                bad=$((bad + 1))
                explain "$(cid "$svc")"
                record "svc:$svc" fail "$svc is not running and healthy"
            done
            break
        fi
        todo=("${left[@]}")
        sleep 5
    done
    if ((bad == 0)); then
        pass "$n services run, healthy where they have a healthcheck"
    fi
}

# Lines of "<service> <id> <status> <start time> <restarts>"
snapshot() {
    local -a ids
    mapfile -t ids < <(project_ids)
    ((${#ids[@]})) || return 0
    docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}} {{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.RestartCount}}' "${ids[@]}" | sort
}

# check_stable <snapshot> <start>: no container of this pass restarted
# within STABLE_SECONDS from the start
check_stable() {
    local svc rest n=0 bad=0
    local -a changed
    for svc in "${SERVICES[@]}"; do
        if gate_turn "svc:$svc"; then n=$((n + 1)); fi
    done
    ((n)) || return 0
    rest=$((STABLE_SECONDS - (SECONDS - $2)))
    if ((rest > 0)); then
        sleep "$rest"
    fi
    mapfile -t changed < <({ diff <(printf '%s\n' "$1") <(snapshot) || true; } | awk '/^[<>]/ { print $2 }' | sort -u)
    for svc in "${changed[@]}"; do
        gate_turn "svc:$svc" || continue
        bad=$((bad + 1))
        explain "$(cid "$svc")"
        record "svc:$svc" fail "$svc restarted during the gate"
    done
    if ((bad == 0)); then
        pass "no container restarted in $((SECONDS - $2))s"
    fi
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

# The chain height from the restricted RPC
chain_height() {
    local body re='"height"[[:space:]]*:[[:space:]]*([0-9]+)'
    body=$(curl -sk --max-time 10 "https://$HTTP_HOST:18089/get_height" 2>/dev/null) || return 1
    [[ $body =~ $re ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Before the change, it notes the height. After the change, the height
# must be at least the one from before.
height_ok() {
    local height
    height=$(chain_height) || return 1
    if [[ $GATE_MODE == pre ]]; then
        if [[ -n $GATE_DIR ]]; then printf '%s\n' "$height" >"$GATE_DIR/height"; fi
        return 0
    fi
    ((height >= ${PRE_HEIGHT:-0}))
}

# The tor in a service runs, and logged "Bootstrapped 100%" since its last
# start. A container that never started has the start time 0001-01-01.
tor_bootstrapped() {
    local id state started logs age
    id=$(cid "$1")
    [[ -n $id ]] || return 1
    read -r state started < <(docker inspect -f '{{.State.Status}} {{.State.StartedAt}}' "$id" 2>/dev/null) || return 1
    [[ $state == running ]] || return 1
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

# The unix socket path of tor's --HiddenServicePort
onion_sock() {
    local id port
    id=$(cid tor)
    [[ -n $id ]] || return 1
    port=$(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$id" 2>/dev/null | flag_value --HiddenServicePort) || return 1
    [[ $port == *unix:* ]] || return 1
    printf '%s\n' "${port##*unix:}"
}

onion_sock_exists() {
    local sock
    sock=$(onion_sock) || return 1
    docker exec "$(cid tor)" test -S "$sock"
}

# onion_answers <http|https>: onion-proxy answers on the onion socket
onion_answers() {
    local sock
    sock=$(onion_sock) || return 1
    exec_ok onion-proxy "$1://localhost/get_height" --unix-socket "$sock"
}

# Prints why tor does not serve $ONION with the key from before the change.
# Exit 0: it does. 1: tor serves no onion (yet). 2: tor serves another name
# or key. 3: tor has no onion service in its flags.
onion_state() {
    local id args dir port state out host key
    id=$(cid tor)
    if [[ -z $id ]] || ! args=$(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$id" 2>/dev/null); then
        echo "tor has no container"
        return 1
    fi
    dir=$(flag_value --HiddenServiceDir <<<"$args")
    port=$(flag_value --HiddenServicePort <<<"$args")
    if [[ -z $dir || $port != *unix:* ]]; then
        echo "tor has no --HiddenServiceDir flag or no unix socket --HiddenServicePort"
        return 3
    fi
    state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null) || state=gone
    if [[ $state != running ]]; then
        echo "tor is $state, so the gate cannot read its onion name and key"
        return 1
    fi
    # shellcheck disable=SC2016 # the container shell expands these
    if ! out=$(docker exec "$id" sh -c 'cat "$1/hostname" && sha256sum < "$1/hs_ed25519_secret_key" | cut -d " " -f 1' sh "$dir" 2>/dev/null); then
        echo "tor has no onion key in $dir"
        return 1
    fi
    host=${out%%$'\n'*}
    key=${out##*$'\n'}
    if [[ $host != "$ONION" ]]; then
        echo "tor serves $host, but the pinned onion is $ONION"
        return 2
    fi
    if [[ $key != "$BASE_KEY" ]]; then
        echo "tor serves $ONION, but with a key that differs from before the deploy"
        return 2
    fi
}

# tor serves the pinned onion name, with the key from before the change
check_onion() {
    local why rc
    gate_turn onion || return 0
    while :; do
        rc=0
        why=$(onion_state) || rc=$?
        ((rc == 1 && SECONDS < GATE_DEADLINE)) || break
        sleep 5
    done
    case $rc in
        0) record onion pass "tor serves $ONION with the same key as before the deploy" ;;
        2) record onion wrong "$why" ;;
        *) record onion fail "$why" ;;
    esac
}

gate_checks() {
    local height="monerod reports its chain height"
    if [[ $GATE_MODE == post && -n $PRE_HEIGHT ]]; then
        height="the chain height is $PRE_HEIGHT or more, as before the change"
    fi
    check http "http://$HTTP_HOST/health answers status OK" http_ok "http://$HTTP_HOST/health" "$STATUS_OK"
    check rpc-443 "RPC on port 443 answers status OK" http_ok "https://$HTTP_HOST:443/get_height" "$STATUS_OK"
    check rpc-18089 "RPC on port 18089 answers status OK" http_ok "https://$HTTP_HOST:18089/get_height" "$STATUS_OK"
    check height "$height" height_ok
    check grafana "Grafana answers, database ok" http_ok "http://$HTTP_HOST/grafana/api/health" '"database"[[:space:]]*:[[:space:]]*"ok"'
    check rpc-proxy "monerod-rpc-proxy reaches monerod" exec_ok monerod-rpc-proxy http://localhost:18081/get_height
    check tor "tor has bootstrapped" tor_bootstrapped tor
    check tor-client "tor-client has bootstrapped" tor_bootstrapped tor-client
    check_onion
    check onion-sock "the onion socket exists in tor" onion_sock_exists
    check onion-http "the onion socket answers plain HTTP" onion_answers http
    check onion-tls "the onion socket answers TLS" onion_answers https
}

# One pass: the containers, the checks, then no restart in STABLE_SECONDS
gate_pass() {
    local before t0
    check_containers
    before=$(snapshot)
    t0=$SECONDS
    gate_checks
    check_stable "$before" "$t0"
}

# gate <pre|post> <seconds> [label]
gate() {
    local id
    GATE_MODE=$1
    GATE_DEADLINE=$((SECONDS + $2))
    log "gate${3:+ $3}: checks for up to $2s"
    GATE_PASS=1
    gate_pass
    [[ $GATE_MODE == post ]] || return 0
    for id in "${!PRE[@]}"; do
        if [[ ${PRE[$id]} != pass ]]; then
            log "gate: now the checks that failed before the change"
            GATE_PASS=2
            gate_pass
            break
        fi
    done
}

# ---------------------------------------------------------------- commands

# docker compose 2.22 or newer. Sets COMPOSE_VERSION.
compose_ok() {
    local major minor
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null) || COMPOSE_VERSION=""
    COMPOSE_VERSION=${COMPOSE_VERSION#v}
    IFS=. read -r major minor _ <<<"$COMPOSE_VERSION"
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
    ((major > 2 || (major == 2 && minor >= 22)))
}

preflight() {
    local env_domain avail dir host key owner mode state commit tracked
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
    if ! compose_ok; then
        die 3 "docker compose ${COMPOSE_VERSION:-(no version)} is too old or missing. The deploy needs 2.22 or newer:" \
            "pull --policy came in 2.22, and up --wait-timeout and depends_on restart came in 2.17."
    fi
    log "docker compose $COMPOSE_VERSION"
    for dir in "$REPO_DIR" "$BACKUP_DIR" "$STATE_DIR"; do
        avail=$(df -Pk "$dir" | awk 'NR == 2 { print $4 }')
        ((${avail:-0} > 1048576)) || die 3 "less than 1 GiB is free for $dir"
    done

    PREV=$(git rev-parse HEAD)
    git fetch -q origin || die 3 "git fetch failed"
    git cat-file -e "$TARGET^{commit}" 2>/dev/null || die 3 "commit $TARGET is not in origin"
    git merge-base --is-ancestor "$TARGET" origin/main || die 3 "commit $TARGET is not on origin/main"
    # A commit that tracks a file that only the box has would replace the
    # box copy, and a rollback from it would delete that file (.env holds
    # the secrets). So neither commit may track one.
    for commit in "$PREV" "$TARGET"; do
        tracked=$(git ls-tree -r --name-only "$commit" -- "${BOX_FILES[@]}") || die 3 "cannot list the files of $commit"
        if [[ -n $tracked ]]; then
            die 3 "commit $commit tracks $(paste -sd ' ' <<<"$tracked"). Only the box may have these files."
        fi
    done

    load_compose_facts || die 3 "docker compose config failed for $PREV"
    state=$(volume_key_state 2>/dev/null) || die 3 "cannot read the onion key in volume $TOR_KEYS_VOLUME"
    read -r host key owner mode <<<"$state"
    [[ $host == "$ONION" ]] || die 3 "the onion key on this box is for ${host:-nothing}, but the pinned onion is $ONION"
    [[ $key =~ ^[0-9a-f]{64}$ ]] || die 3 "cannot hash the onion key"
    if [[ -n $KEY_SHA256 && $key != "$KEY_SHA256" ]]; then
        die 3 "the onion key on this box does not have the sha256 from --key-sha256"
    fi
    BASE_KEY=$key
    pass "the onion key on this box is for $ONION${KEY_SHA256:+, with the sha256 from --key-sha256}"
    if [[ "$owner $mode" != "$TOR_USER 700" ]]; then
        warn "the onion key dir is $owner mode $mode, expected $TOR_USER mode 700"
    fi
    backup_tor_keys || die 3 "the onion key backup failed"
}

# phase <command...>: runs one part of the deploy in a subshell that stops
# at the first failed step. Sets PHASE_RC. Call it as a plain command, not
# in "if" or "||": there bash ignores errexit.
phase() {
    set +e
    (
        set -e
        trap 'on_err $? "$BASH_COMMAND"' ERR
        "$@"
    )
    PHASE_RC=$?
    set -e
}

forward() {
    switch_to "$TARGET" forward
    gate post "$GATE_TIMEOUT" "after the change"
}

back() {
    switch_to "$PREV"
    gate post "$GATE_TIMEOUT" "after the rollback"
}

# Reads the results of the gate before the change into PRE and PRE_HEIGHT.
# A check with two results keeps the worse one.
load_pre() {
    local id result
    PRE=()
    PRE_HEIGHT=""
    if [[ -f $GATE_DIR/pre ]]; then
        while IFS=$'\t' read -r id result _; do
            case ${PRE[$id]:-pass}/$result in
                pass/* | fail/wrong) PRE[$id]=$result ;;
            esac
        done <"$GATE_DIR/pre"
    fi
    if [[ -s $GATE_DIR/height ]]; then
        PRE_HEIGHT=$(<"$GATE_DIR/height")
    fi
}

# Lists the checks of the last gate that failed before the change and
# still fail. scripts/deploy-ssh.sh reads these lines for the alert.
summarize_known() {
    local id result text
    local -A seen=()
    [[ -s $GATE_FILE ]] || return 0
    while IFS=$'\t' read -r id result text; do
        if [[ $result != pass && -z ${seen[$id]:-} ]] && ! is_regression "$id" "$result"; then
            seen[$id]=1
            warn "$KNOWN: $text"
        fi
    done <"$GATE_FILE"
}

# The EXIT trap of deploy: it removes the gate results and writes the exit
# code for follow
deploy_exit() {
    local rc=$?
    if [[ -n $GATE_DIR ]]; then
        rm -rf -- "$GATE_DIR"
    fi
    if [[ -n $RUN_DIR ]]; then
        echo "$rc" >"$RUN_DIR/status.tmp" && mv "$RUN_DIR/status.tmp" "$RUN_DIR/status"
    fi
}

cmd_deploy() {
    local svc old new
    need_target
    need_domain
    need_onion
    check_key_sha256
    if [[ -n $RUN_DIR ]]; then
        need_run_dir
        echo "$$" >"$RUN_DIR/pid"
    fi
    trap deploy_exit EXIT
    preflight
    GATE_DIR=$(mktemp -d "$STATE_DIR/gate.XXXXXX")
    log "deploy $TARGET to $DOMAIN (the box runs $PREV)"

    # The gate before the change only reads. It records which checks pass,
    # so that a check that fails already cannot cause a rollback later.
    GATE_FILE=$GATE_DIR/pre
    phase gate pre "$PRE_GATE_TIMEOUT" "before the change"
    if ((PHASE_RC != 0)); then
        warn "the gate before the change stopped early. A check with no result counts as one that passed."
    fi
    load_pre

    GATE_FILE=$GATE_DIR/post
    phase forward
    if ((PHASE_RC == 0)); then
        summarize_known
        pass "deployed $TARGET to $DOMAIN"
        exit 0
    fi

    if [[ -s $GATE_DIR/stateful ]]; then
        while read -r svc old new; do
            fail "$svc keeps data in a volume, and the deploy changed its image from $old to $new"
        done <"$GATE_DIR/stateful"
        fail "MANUAL ACTION NEEDED on $DOMAIN. The deploy of $TARGET failed, and the old image could fail on data that the new image migrated. So there was no automatic rollback, and the box stays on $TARGET."
        exit 5
    fi

    fail "the deploy of $TARGET failed. Roll back to $PREV"
    GATE_FILE=$GATE_DIR/back
    phase back
    if ((PHASE_RC == 0)); then
        summarize_known
        fail "rolled back to $PREV, and no check failed that passed before the change. $TARGET is not deployed."
        exit 1
    fi
    fail "THE ROLLBACK FAILED. $DOMAIN runs a broken stack and needs a person now."
    exit 2
}

cmd_start() {
    need_run_dir
    [[ -f $SELF ]] || die 3 "start runs deploy.sh again, so it needs it as a file, not on stdin"
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
    check_key_sha256
    cd "$REPO_DIR" 2>/dev/null || die 3 "no checkout at $REPO_DIR"
    load_compose_facts
    if [[ -n $KEY_SHA256 ]]; then
        BASE_KEY=$KEY_SHA256
    else
        state=$(volume_key_state)
        read -r _ BASE_KEY _ <<<"$state"
    fi
    gate post "$GATE_TIMEOUT"
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
