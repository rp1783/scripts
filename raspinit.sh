#!/bin/bash
set -e

ADGUARD_DIR="/opt/adguardhome"
COMPOSE_FILE="$ADGUARD_DIR/docker-compose.yml"
DDCLIENT_CONFIG="/etc/ddclient.conf"

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

echo "🔄 Starting setup on $(hostname)..."

### 1. System Update
echo "📦 Updating package list..."
apt update -y

### 2. Install Docker
if ! command -v docker &>/dev/null; then
  echo "🐳 Installing Docker via convenience script..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  echo "✅ Docker already installed."
fi

# Ensure docker compose plugin is installed
if ! docker compose version &>/dev/null; then
  echo "🔧 Installing Docker Compose plugin..."
  apt install -y docker-compose-plugin
else
  echo "✅ Docker Compose plugin already installed."
fi

### 3. Install Tailscale
if ! command -v tailscale &>/dev/null; then
  echo "🧩 Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
else
  echo "✅ Tailscale is already installed."
fi

# Connect to Tailscale if not already connected
if ! tailscale status | grep -q "Logged in as"; then
  echo "🔐 Tailscale is not connected."
  read -p "Enter your Tailscale auth key: " TAILSCALE_AUTHKEY
  tailscale up --authkey "$TAILSCALE_AUTHKEY"
else
  echo "✅ Tailscale is already connected: $(tailscale status | grep 'Logged in as')"
fi

### 4. Install and Configure ddclient (Cloudflare)
if ! dpkg -s ddclient &>/dev/null; then
  echo "🌐 Installing ddclient..."
  apt install -y ddclient
fi

if ! grep -q "cloudflare" "$DDCLIENT_CONFIG" 2>/dev/null; then
  echo "🛠️ Configuring ddclient for Cloudflare..."

  read -p "Enter your Cloudflare zone (e.g. example.com): " cf_zone
  read -p "Enter the full hostname to update (e.g. home.example.com): " cf_hostname
  read -p "Enter your Cloudflare API token (with DNS edit permissions): " cf_token
  read -p "Enter your network interface (e.g. eth0 or wlan0): " net_iface

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
  echo "✅ ddclient configured and running."
else
  echo "✅ ddclient already configured for Cloudflare."
fi

### 5. Deploy AdGuard Home via Docker Compose
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "📦 Creating AdGuard Home Docker Compose file..."
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
fi

if ! docker ps --format '{{.Names}}' | grep -q "^adguardhome$"; then
  echo "🚀 Starting AdGuard Home..."
  docker compose -f "$COMPOSE_FILE" up -d
else
  echo "✅ AdGuard Home is already running."
fi

### 🎉 Done
echo ""
echo "🎉 Setup complete!"
echo "🌐 Access AdGuard Home: http://<your_pi_ip>:3000"
echo "🛡️  Tailscale is connected and syncing private network"
echo "🌍 ddclient will update your Cloudflare DNS every 5 minutes"
