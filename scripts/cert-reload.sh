#!/usr/bin/env bash
# monerod (epee) loads the TLS cert once at startup and never re-reads it,
# so certbot renewals silently expire in RAM ~90 days later. Restart
# monerod whenever the cert on disk is newer than the running container.
# nginx in onion-proxy serves the same cert to the onion TLS clients, and it
# loads the cert only at start and at "nginx -s reload". Reload it whenever
# the cert that it serves is not the cert on disk.
# Installed as /etc/cron.daily/monerod-cert-reload by setup.sh and deploy.sh.
set -euo pipefail

# scripts/deploy.sh holds this lock while it deploys and checks the stack.
# Wait for it, so this restart never lands in the middle of a deploy.
LOCK=/var/lib/monero-node-deploy/lock
install -d -m 700 "${LOCK%/*}"
exec 9>"$LOCK"
if ! flock -w 1800 9; then
    echo "monerod-cert-reload: a deploy held $LOCK for 30 minutes. The next daily run tries again." >&2
    exit 1
fi

CERT=$(compgen -G "/var/lib/docker/volumes/monero-node_certbot-conf/_data/live/*/fullchain.pem" | head -1)
[ -n "$CERT" ] || exit 0

CERT_TIME=$(stat -L -c %Y "$CERT")
STARTED=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' monerod)" +%s)

if [ "$CERT_TIME" -gt "$STARTED" ]; then
    docker restart monerod
fi

# The cert check reads the cert that onion-proxy serves, not a time, so a
# renewal is not missed when a deploy restarted monerod first. A reload is
# graceful: requests in progress finish, and idle pool sockets close cleanly.
[ "$(docker inspect -f '{{.State.Running}}' onion-proxy 2>/dev/null || true)" = true ] || exit 0
SOCK=/var/lib/docker/volumes/monero-node_onion-sock/_data/monerod.sock
sha256() { openssl x509 -noout -fingerprint -sha256 2>/dev/null || true; }
served() { openssl s_client -unix "$SOCK" </dev/null 2>/dev/null | sha256; }
WANT=$(sha256 <"$CERT")
[ -n "$WANT" ] || exit 0
[ "$(served)" != "$WANT" ] || exit 0
docker exec onion-proxy nginx -s reload
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    [ "$(served)" != "$WANT" ] || exit 0
done
echo "monerod-cert-reload: onion-proxy does not serve the cert on disk after nginx -s reload. See docker logs --tail 20 onion-proxy." >&2
exit 1
