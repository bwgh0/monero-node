#!/usr/bin/env bash
set -euo pipefail

# Fresh VPS provisioning script for monero-node
# Usage: DOMAIN=eu.node.monero.one scripts/setup.sh [--extra-domain <name>]... [--no-start]
#   --extra-domain  also put this name on the first TLS cert (repeat it for more names)
#   --no-start      start no service at the end, so tor makes no onion key
# Run it from a checkout at /opt/monero-node, or from another checkout. From
# another checkout, it copies the files to /opt/monero-node.

DOMAIN="${DOMAIN:?Set DOMAIN environment variable (e.g. eu.node.monero.one)}"
EXTRA_DOMAINS=()
START=1
while [ $# -gt 0 ]; do
    case "$1" in
        --extra-domain)
            # A name starts with a letter or digit, so a flag is never taken as one
            if [[ ! ${2:-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
                echo "--extra-domain needs a host name" >&2
                exit 1
            fi
            EXTRA_DOMAINS+=("$2")
            shift 2
            ;;
        --no-start)
            START=0
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: DOMAIN=<name> scripts/setup.sh [--extra-domain <name>]... [--no-start]" >&2
            exit 1
            ;;
    esac
done

# The checkout of this script. Find it before the cd below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Provisioning monero-node for ${DOMAIN}"

# Update system
echo "==> Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# Install Docker from official apt repo with GPG verification
if ! command -v docker &> /dev/null; then
    echo "==> Installing Docker..."
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck disable=SC1091 # /etc/os-release is on the box, not here
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
fi

# Harden SSH
echo "==> Hardening SSH..."
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# Kernel hardening
echo "==> Applying kernel hardening..."
cat > /etc/sysctl.d/99-monero-node.conf << 'SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
SYSCTL
sysctl --system > /dev/null

# Firewall setup (UFW)
echo "==> Configuring firewall..."
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     # SSH
ufw allow 80/tcp     # HTTP (ACME + health checks)
ufw allow 443/tcp    # HTTPS (monerod native TLS RPC)
ufw allow 18080/tcp  # monerod P2P
ufw allow 18089/tcp  # monerod restricted RPC (legacy port)
ufw --force enable

# Create app directory
APP_DIR="/opt/monero-node"
mkdir -p "${APP_DIR}"

# Write environment file
echo "==> Writing .env..."
if [ ! -f "${APP_DIR}/.env" ]; then
    cat > "${APP_DIR}/.env" << EOF
DOMAIN=${DOMAIN}
GRAFANA_PASSWORD=$(openssl rand -base64 24)
EOF
    echo "    Generated random Grafana password — see ${APP_DIR}/.env"
else
    echo "    .env already exists, skipping"
fi

# Set up AWS credentials directory for certbot DNS-01
mkdir -p "${APP_DIR}/aws"
if [ ! -f "${APP_DIR}/aws/credentials" ]; then
    echo "    NOTE: Add AWS credentials to ${APP_DIR}/aws/credentials for DNS-01 cert renewal"
fi

if [ "${START}" -eq 1 ]; then
    echo "==> Starting services..."
else
    echo "==> Preparing services (--no-start: none of them starts)..."
fi
cd "${APP_DIR}"

# Copy compose and config files from the checkout of this script. A checkout
# at /opt/monero-node already has them.
if [ "${SCRIPT_DIR}" -ef "${APP_DIR}" ]; then
    echo "    Using the checkout at ${APP_DIR}"
else
    cp "${SCRIPT_DIR}/docker-compose.yml" "${APP_DIR}/"
    cp "${SCRIPT_DIR}/nginx.conf" "${APP_DIR}/"
    cp "${SCRIPT_DIR}/onion-proxy.conf" "${APP_DIR}/"
    cp -r "${SCRIPT_DIR}/monitoring" "${SCRIPT_DIR}/scripts" "${APP_DIR}/"
fi

# Substitute domain in nginx.conf, onion-proxy.conf (the cert path) and the
# alert rules (they tell the probes of this box from those of the other box
# by its domain)
sed -i "s/\${DOMAIN}/${DOMAIN}/g" "${APP_DIR}/nginx.conf" "${APP_DIR}/onion-proxy.conf" "${APP_DIR}"/monitoring/grafana/provisioning/alerting/*.yml

# Generate initial Let's Encrypt cert (monerod loads it for native TLS). The
# cert is in the certbot-conf volume, so look for it there. Let's Encrypt
# allows only 5 duplicate certs a week. The --extra-domain names go on this
# first cert only. certbot names the cert after the first -d (DOMAIN), so
# its path stays live/${DOMAIN}.
if ! docker compose run --rm --no-deps -T --entrypoint sh certbot \
    -c 'test -d "/etc/letsencrypt/live/$1"' sh "${DOMAIN}"; then
    echo "==> Generating initial TLS certificate via DNS-01..."
    CERT_NAMES=(-d "${DOMAIN}")
    for name in "${EXTRA_DOMAINS[@]}"; do
        CERT_NAMES+=(-d "${name}")
    done
    # The entrypoint of the certbot service is the renew loop, and "docker
    # compose run" keeps it. Without --entrypoint, the loop ignores these
    # arguments, runs forever and gets no first cert.
    docker compose run --rm --entrypoint certbot certbot certonly \
        --dns-route53 \
        "${CERT_NAMES[@]}" \
        --non-interactive \
        --agree-tos \
        --email "admin@monero.one" \
        --no-eff-email
    # Make certs readable by monerod (runs as non-root). The image and the
    # volume come from the certbot service in docker-compose.yml.
    docker compose run --rm --no-deps -T --entrypoint sh certbot \
        -c 'chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive && chmod -R a+rX /etc/letsencrypt/live/ /etc/letsencrypt/archive/' 2>/dev/null || true
else
    echo "    TLS certificate already exists for ${DOMAIN}"
    if [ "${#EXTRA_DOMAINS[@]}" -gt 0 ]; then
        echo "    It keeps its names. --extra-domain adds names to a new cert only."
    fi
fi

# Install cert-reload cron — monerod never re-reads TLS certs after startup,
# so a renewed cert must trigger a container restart or it expires in RAM
echo "==> Installing cert-reload cron..."
cp "${SCRIPT_DIR}/scripts/cert-reload.sh" /etc/cron.daily/monerod-cert-reload
chmod 755 /etc/cron.daily/monerod-cert-reload

# Container state metrics for the Grafana container alerts
echo "==> Installing docker-metrics cron..."
install -d -m 755 /var/lib/node-exporter/textfile
install -m 644 "${SCRIPT_DIR}/scripts/docker-metrics.cron" /etc/cron.d/monero-node-docker-metrics

# Capacity metrics every minute and the weekly digest (docs/capacity.md)
echo "==> Installing capacity cron..."
install -d -m 755 /var/lib/monero-node-capacity
install -m 644 "${SCRIPT_DIR}/scripts/capacity.cron" /etc/cron.d/monero-node-capacity

# The time of the last good watchdog run, for Watchdog Silent (docs/monitoring.md)
echo "==> Installing watchdog-metrics cron..."
install -m 644 "${SCRIPT_DIR}/scripts/watchdog-metrics.cron" /etc/cron.d/monero-node-watchdog-metrics
python3 "${SCRIPT_DIR}/scripts/watchdog-metrics.py" || echo "    The GitHub API call failed. Cron tries again in 5 minutes."

# Tor runs as uid 104. That uid owns the onion keys on the existing boxes.
# A new tor-keys volume belongs to root, so give it to uid 104 first.
# This touches only the volume root, never the keys inside it.
docker compose run --rm --no-deps --user 0:0 --cap-add CHOWN --cap-add FOWNER \
    --entrypoint /bin/sh tor \
    -c 'chown 104:107 /var/lib/tor/hidden_service && chmod 700 /var/lib/tor/hidden_service'

# --no-start ends here, with no service started. At its first start, tor
# makes a new onion key unless the tor-keys volume already has one.
if [ "${START}" -eq 0 ]; then
    echo ""
    echo "==> Setup complete. No service started (--no-start)."
    echo "    Put the onion key in the tor-keys volume before tor starts, or tor makes a new one."
    echo "    Start services: docker compose up -d [service...]"
    exit 0
fi

docker compose up -d

echo "==> Waiting for services to start..."
sleep 10

# Check health
echo "==> Checking health..."
if curl -sf "http://localhost/health" > /dev/null 2>&1; then
    echo "==> Node is running and healthy!"
else
    echo "==> Services starting, check: docker compose logs -f"
fi

# Print Tor .onion address (may take a minute to generate)
echo "==> Tor hidden service address (may take a moment):"
sleep 5
docker exec tor cat /var/lib/tor/hidden_service/monerod/hostname 2>/dev/null || echo "(not yet generated — check again in a minute: docker exec tor cat /var/lib/tor/hidden_service/monerod/hostname)"

echo ""
echo "==> Setup complete!"
echo "    HTTPS RPC: https://${DOMAIN}"
echo "    P2P:       ${DOMAIN}:18080"
echo "    Tor:       (see .onion address above)"
echo "    Grafana:   ssh -L 3000:localhost:80 root@${DOMAIN} then open http://localhost:3000/grafana/"
echo ""
echo "    Logs:      docker compose logs -f"
echo "    Status:    docker compose ps"
echo "    .onion:    docker exec tor cat /var/lib/tor/hidden_service/monerod/hostname"
