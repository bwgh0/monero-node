#!/usr/bin/env bash
set -euo pipefail

# Fresh VPS provisioning script for monero-node
# Usage: DOMAIN=eu.node.monero.one ./setup.sh

DOMAIN="${DOMAIN:?Set DOMAIN environment variable (e.g. eu.node.monero.one)}"

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

echo "==> Starting services..."
cd "${APP_DIR}"

# Copy compose and config files (assumes they're in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "${SCRIPT_DIR}/docker-compose.yml" "${APP_DIR}/"
cp "${SCRIPT_DIR}/nginx.conf" "${APP_DIR}/"

# Substitute domain in nginx.conf
sed -i "s/\${DOMAIN}/${DOMAIN}/g" "${APP_DIR}/nginx.conf"

# Generate initial Let's Encrypt cert (monerod loads it for native TLS)
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    echo "==> Generating initial TLS certificate via DNS-01..."
    docker compose run --rm certbot certbot certonly \
        --dns-route53 \
        -d "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "admin@monero.one" \
        --no-eff-email
    # Make private key readable by monerod (runs as non-root)
    chmod 644 /etc/letsencrypt/archive/*/privkey*.pem 2>/dev/null || true
else
    echo "    TLS certificate already exists for ${DOMAIN}"
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
