#!/usr/bin/env bash
# Runs scripts/deploy.sh on one box, from the deploy workflow or by hand.
#   scripts/deploy-ssh.sh <host> <domain> <onion> <commit> [--allow-mixed-data]
# Env: SSH_KEY (the private key; by hand, leave it unset to use your own ssh
# keys), KNOWN_HOSTS (the pinned host keys, default .github/known_hosts).
# By hand, from the repo root, with the commit on origin/main:
#   scripts/deploy-ssh.sh eu.node.monero.one eu.node.monero.one <EU onion> "$(git rev-parse origin/main)"
# By hand only: add --allow-mixed-data to deploy a new monerod image together with other changes.
#
# It copies this commit's deploy.sh to the box and starts it there detached
# from SSH, so a dropped connection cannot stop a deploy or a rollback
# halfway. Then it follows the log until the deploy ends and exits with the
# deploy's code (see scripts/deploy.sh). It writes rc=<code> to GITHUB_OUTPUT,
# and already_failing=<checks>: the checks that failed before the deploy and
# still fail after it.
set -euo pipefail

host=$1 domain=$2 onion=$3 commit=$4 mixed=${5:-}
[[ $host =~ ^[a-z0-9.-]+$ && $domain =~ ^[a-z0-9.-]+$ ]] || { echo "::error::bad host or domain"; exit 3; }
[[ $onion =~ ^[a-z2-7]{56}\.onion$ ]] || { echo "::error::bad onion name"; exit 3; }
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad commit sha"; exit 3; }
if (($# > 5)) || [[ $mixed != "" && $mixed != --allow-mixed-data ]]; then
    echo "::error::bad arguments after the commit"
    exit 3
fi
if [[ -n $mixed && ${GITHUB_ACTIONS:-} == true ]]; then
    echo "::error::--allow-mixed-data is for a deploy by hand only"
    exit 3
fi
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    : "${SSH_KEY:?SSH_KEY is empty. Is the secret set?}"
    # GitHub hides a secret as a whole. A key has many lines, so hide each line too.
    while IFS= read -r line; do
        if [[ -n $line ]]; then echo "::add-mask::$line"; fi
    done <<<"$SSH_KEY"
fi
known_hosts=$(readlink -f "${KNOWN_HOSTS:-.github/known_hosts}")
# A run dir name is <workflow run id>-<attempt>, or local-<unix time> by hand
if [[ -n ${GITHUB_RUN_ID:-} ]]; then
    run_id=$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}
else
    run_id=local-$(date +%s)
fi
# RUNS_DIR is for ci/simulate-deploy.sh. It must match STATE_DIR on the box.
run_dir=${RUNS_DIR:-/var/lib/monero-node-deploy/runs}/$run_id
[[ $run_dir =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "::error::bad run dir $run_dir"; exit 3; }
remote=$run_dir/deploy.sh

if ! grep -q "^$host ssh-ed25519 " "$known_hosts"; then
    echo "::error::no pinned ssh-ed25519 host key for $host in $known_hosts"
    exit 3
fi

key=""
out=$(mktemp) # a copy of the box output
trap 'rm -f "$out" ${key:+"$key"}' EXIT
ssh_opts=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o HostKeyAlgorithms=ssh-ed25519
    -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR
)
if [[ -n ${SSH_KEY:-} ]]; then
    key=$(mktemp)
    chmod 600 "$key"
    printf '%s\n' "$SSH_KEY" >"$key"
    ssh_opts=(-i "$key" -o IdentitiesOnly=yes "${ssh_opts[@]}")
fi
# The remote command gets only checked values: hex, host names, paths
# shellcheck disable=SC2029
on_box() { ssh "${ssh_opts[@]}" "root@$host" "$@"; }

# The box output is not trusted to send workflow commands
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
commands_off() { echo "::stop-commands::$token"; }
commands_on() { echo "::$token::"; }

rc=4
for try in 1 2 3; do
    if on_box "install -d -m 700 $run_dir && cat > $remote" <scripts/deploy.sh; then
        rc=0
        break
    fi
    echo "upload to $host failed ($try/3)"
    sleep 10
done

if ((rc == 0)); then
    echo "deploy $commit to $host"
    commands_off
    set +e
    on_box bash "$remote" start --run-dir "$run_dir" --target "$commit" --domain "$domain" --onion "$onion" ${mixed:+"$mixed"} | tee -a "$out"
    rc=${PIPESTATUS[0]}
    for try in 1 2 3 4 5 6 7 8 9 10; do
        ((rc == 255)) || break
        echo "--- SSH to $host dropped. The deploy goes on there. Follow it again ($try/10)."
        sleep 15
        on_box bash "$remote" follow --run-dir "$run_dir" | tee -a "$out"
        rc=${PIPESTATUS[0]}
    done
    set -e
    commands_on
fi

# The box output is not trusted, so only plain characters go on to the alert
known=$(sed -n 's/^[0-9:]*  WARN  already failing before the change: //p' "$out" |
    tr -cd '[:alnum:] .,:/()_\n-' | sort -u | paste -sd ';' - | sed 's/;/; /g')
{
    echo "rc=$rc"
    echo "already_failing=$known"
} >>"${GITHUB_OUTPUT:-/dev/null}"
if [[ -n $known ]]; then
    echo "::warning title=$domain checks already failing::These checks failed before the deploy and still fail: $known"
fi
case $rc in
    0) echo "deployed $commit to $domain, and no check regressed" ;;
    1) echo "::error title=$domain rolled back::The deploy failed a step or broke a check, so the box went back to the previous commit. After the rollback, every check passed that passed before." ;;
    2) echo "::error title=$domain ROLLBACK FAILED::The deploy failed, and the rollback failed too. The box needs a person now." ;;
    3) echo "::error title=$domain not deployed::The deploy stopped before it changed anything. See the log." ;;
    4) echo "::error title=$domain not deployed::The deploy did not start (SSH)." ;;
    5) echo "::error title=$domain MANUAL ACTION NEEDED::The deploy failed after a service that keeps data, like monerod, started on a new image. A rollback could run the old image on migrated data, so the box stays on $commit. A person must check it now." ;;
    *) echo "::error title=$domain unknown result::No result from the box (exit $rc). See the log and the run dir $run_dir on the box." ;;
esac
exit "$rc"
