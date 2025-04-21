#!/bin/bash
set -e

ADGUARD_DIR="/opt/adguardhome"
COMPOSE_FILE="$ADGUARD_DIR/docker-compose.yml"
DDCLIENT_CONFIG="/etc/ddclient.conf"

# Ensure root
if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

# Prompt for credentials
read -p "Enter your Cloudflare Zone (e.g. example.com): " cf_zone
read -p "Enter the full hostname you want to update (e.g. home.example.com): " cf_hostname
read -p "Enter your Cloudflare API token (DNS edit permission): " cf_token
read -p "Enter your Tailscale auth key: " ts_key
read -p "Enter the network interface (e.g. eth0): " net_iface

# Update system
echo "[+] Updating system..."
apt update -y && apt upgrade -y

# Install dependencies
echo "[+] Installing packages..."
apt install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  ddclient \
  jq

# Install Docker
echo "[+] Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# Install & authenticate Tailscale
echo "[+] Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
echo "[+] Connecting to Tailscale..."
tailscale up --authkey "$ts_key" || {
  echo "[-] Tailscale login failed. Exiting."
  exit 1
}

# Configure ddclient for Cloudflare
echo "[+] Configuring ddclient for Cloudflare..."
cat <<EOF > "$DDCLIENT_CONFIG"
daemon=300
ssl=yes
use=if, if=$net_iface
protocol=cloudflare,
zone=$cf_zone
ttl=1
login=token
password=$cf_token
$cf_hostname
EOF

chmod 600 "$DDCLIENT_CONFIG"
systemctl enable --now ddclient

# Setup AdGuard Home via Docker Compose
echo "[+] Deploying AdGuard Home..."
mkdir -p "$ADGUARD_DIR"
cat <<EOF > "$COMPOSE_FILE"
version: '3'
services:
  adguardhome:
    container_name: adguardhome
    image: adguard/adguardhome:latest
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80"
      - "3000:3000"
    volumes:
      - ${ADGUARD_DIR}/work:/opt/adguardhome/work
      - ${ADGUARD_DIR}/conf:/opt/adguardhome/conf
EOF

docker compose -f "$COMPOSE_FILE" up -d

echo "✅ All done!"
echo "• Visit http://<your_server_ip>:3000 to finish AdGuard Home setup"
echo "• Your IP will update automatically via Cloudflare every 5 minutes"
