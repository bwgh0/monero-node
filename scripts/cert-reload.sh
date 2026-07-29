#!/usr/bin/env bash
# monerod (epee) loads the TLS cert once at startup and never re-reads it,
# so certbot renewals silently expire in RAM ~90 days later. Restart
# monerod whenever the cert on disk is newer than the running container.
# Installed as /etc/cron.daily/monerod-cert-reload by setup.sh.
set -euo pipefail

CERT=$(compgen -G "/var/lib/docker/volumes/monero-node_certbot-conf/_data/live/*/fullchain.pem" | head -1)
[ -n "$CERT" ] || exit 0

CERT_TIME=$(stat -L -c %Y "$CERT")
STARTED=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' monerod)" +%s)

if [ "$CERT_TIME" -gt "$STARTED" ]; then
    docker restart monerod
fi
