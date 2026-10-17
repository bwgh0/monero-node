#!/usr/bin/env bash
# Runs scripts/deploy.sh on one box, from the deploy workflow.
#   scripts/deploy-ssh.sh <host> <domain> <onion> <commit>
# Env: SSH_KEY (the private key), KNOWN_HOSTS (the pinned host keys).
#
# It copies this commit's deploy.sh to the box and starts it there detached
# from SSH, so a dropped connection cannot stop a deploy or a rollback
# halfway. Then it follows the log until the deploy ends and exits with the
# deploy's code (see scripts/deploy.sh). It writes rc=<code> to GITHUB_OUTPUT.
set -euo pipefail

host=$1 domain=$2 onion=$3 commit=$4
[[ $host =~ ^[a-z0-9.-]+$ && $domain =~ ^[a-z0-9.-]+$ ]] || { echo "::error::bad host or domain"; exit 3; }
[[ $onion =~ ^[a-z2-7]{56}\.onion$ ]] || { echo "::error::bad onion name"; exit 3; }
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad commit sha"; exit 3; }
: "${SSH_KEY:?SSH_KEY is empty. Is the secret set?}"
known_hosts=$(readlink -f "${KNOWN_HOSTS:-.github/known_hosts}")
run_dir=/var/lib/monero-node-deploy/runs/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}
remote=$run_dir/deploy.sh

if ! grep -q "^$host ssh-ed25519 " "$known_hosts"; then
    echo "::error::no pinned ssh-ed25519 host key for $host in $known_hosts"
    exit 3
fi

key=$(mktemp)
trap 'rm -f "$key"' EXIT
chmod 600 "$key"
printf '%s\n' "$SSH_KEY" >"$key"

ssh_opts=(
    -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o HostKeyAlgorithms=ssh-ed25519
    -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR
)
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
    on_box bash "$remote" start --run-dir "$run_dir" --target "$commit" --domain "$domain" --onion "$onion"
    rc=$?
    for try in 1 2 3 4 5 6 7 8 9 10; do
        ((rc == 255)) || break
        echo "--- SSH to $host dropped. The deploy goes on there. Follow it again ($try/10)."
        sleep 15
        on_box bash "$remote" follow --run-dir "$run_dir"
        rc=$?
    done
    set -e
    commands_on
fi

echo "rc=$rc" >>"${GITHUB_OUTPUT:-/dev/null}"
case $rc in
    0) echo "deployed $commit to $domain, and the checks passed" ;;
    1) echo "::error title=$domain rolled back::The deploy failed its checks, so the box went back to the previous commit. That commit passed the checks." ;;
    2) echo "::error title=$domain ROLLBACK FAILED::The deploy failed, and the rollback failed too. The box needs a person now." ;;
    3) echo "::error title=$domain not deployed::The deploy stopped before it changed anything. See the log." ;;
    4) echo "::error title=$domain not deployed::The deploy did not start (SSH)." ;;
    *) echo "::error title=$domain unknown result::No result from the box (exit $rc). See the log and the run dir $run_dir on the box." ;;
esac
exit "$rc"
