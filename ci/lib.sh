# Helpers for ci/smoke.sh and ci/simulate-deploy.sh. Source it.
# shellcheck shell=bash

step() { printf '\n==> %s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
bad() {
    printf '::error::%s\n' "$*"
    exit 1
}

# CI logs are public. Mask IPs in container output, and indent it.
mask() {
    sed -E -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g' \
        -e 's/([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}/x:x::x/g' \
        -e 's/^/    | /'
}

# copy_tree <from> <to>: the files that git tracks or would track
copy_tree() {
    mkdir -p "$2"
    git -C "$1" ls-files -z --cached --others --exclude-standard |
        tar -C "$1" --null -T - -cf - | tar -C "$2" -xf -
}

# seed_certs <domain>: a self-signed cert where monerod expects the Let's Encrypt one
seed_certs() {
    local domain=$1 tmp
    tmp=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=$domain" \
        -keyout "$tmp/privkey.pem" -out "$tmp/fullchain.pem" 2>/dev/null
    tar -C "$tmp" -cf - privkey.pem fullchain.pem |
        docker compose run --rm --no-deps -T --entrypoint sh certbot -c "
            mkdir -p /etc/letsencrypt/live/$domain &&
            tar -C /etc/letsencrypt/live/$domain -xf - &&
            chmod 755 /etc/letsencrypt/live /etc/letsencrypt/live/$domain &&
            chmod 644 /etc/letsencrypt/live/$domain/privkey.pem /etc/letsencrypt/live/$domain/fullchain.pem"
    rm -rf "$tmp"
}

# A new tor-keys volume belongs to root. Give it to the tor uid, as setup.sh
# does. The volume root goes last: root has no DAC override in here.
seed_tor_dir() {
    docker compose run --rm --no-deps -T --user 0:0 --cap-add CHOWN --cap-add FOWNER \
        --entrypoint sh tor -c '
            d=/var/lib/tor/hidden_service &&
            mkdir -p "$d/monerod" &&
            chown 104:107 "$d/monerod" && chmod 700 "$d/monerod" &&
            chown 104:107 "$d" && chmod 700 "$d"'
}

# Prints the onion name once tor has written it
onion_name() {
    local i
    for ((i = 0; i < 60; i++)); do
        if docker compose exec -T tor cat /var/lib/tor/hidden_service/monerod/hostname 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# sha256 of the onion secret key that tor uses
onion_key_sha256() {
    docker compose exec -T tor sha256sum /var/lib/tor/hidden_service/monerod/hs_ed25519_secret_key | cut -d ' ' -f 1
}

# Removes the stack and its volumes. A recreated container takes over the
# anonymous volumes of the old one, and "down -v" leaves those behind. So
# this also removes the anonymous volumes that the stack's containers use.
teardown() {
    local -a ids anon=()
    mapfile -t ids < <(docker compose ps -aq 2>/dev/null || true)
    if ((${#ids[@]})); then
        mapfile -t anon < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "${ids[@]}" 2>/dev/null |
            grep -E '^[0-9a-f]{64}$' | sort -u || true)
    fi
    docker compose down -v --remove-orphans --timeout 10 >/dev/null 2>&1 || true
    if ((${#anon[@]})); then
        docker volume rm "${anon[@]}" >/dev/null 2>&1 || true
    fi
}

# State and last log lines of every service, with workflow commands off
dump_stack() {
    local token svc
    local -a services
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    echo "::stop-commands::$token"
    docker compose ps -a 2>&1 | mask
    mapfile -t services < <(docker compose config --services 2>/dev/null)
    for svc in "${services[@]}"; do
        echo "--- $svc"
        docker compose logs --no-color --tail 40 "$svc" 2>&1 | mask
    done
    echo "::$token::"
}
