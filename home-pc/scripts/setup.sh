#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Home PC Bootstrap Script (Production-ready)
# -----------------------------

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
CONFIG_FILE="$PROJECT_ROOT/config/home-pc.env.local"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "==> Loading default configuration from $PROJECT_ROOT/config/home-pc.env"
    source "$PROJECT_ROOT/config/home-pc.env"
fi

# -----------------------------
# Update system
# -----------------------------
echo "==> Updating system..."
apt update -y && apt upgrade -y

apt install -y curl git ufw jq

# -----------------------------
# Install Docker + Compose
# -----------------------------
echo "==> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

echo "==> Installing latest Docker Compose..."
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
curl -L "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# -----------------------------
# Install Tailscale
# -----------------------------
echo "==> Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "==> Starting Tailscale..."
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale up --authkey="$TAILSCALE_AUTHKEY"
else
    echo "No TAILSCALE_AUTHKEY provided, manual authentication required:"
    tailscale up
fi

# -----------------------------
# Detect VPS Tailscale IP
# -----------------------------
echo "==> Detecting VPS Tailscale IP..."
VPS_TAILSCALE_IP=$(tailscale status --json | jq -r ".Peer[] | select(.HostName==\"$VPS_HOSTNAME\") | .Addresses[0]")

if [[ -z "$VPS_TAILSCALE_IP" ]]; then
    echo "ERROR: Could not detect VPS Tailscale IP. Set VPS_IP manually in env file."
    VPS_TAILSCALE_IP="${VPS_IP:-}"
    if [[ -z "$VPS_TAILSCALE_IP" ]]; then
        exit 1
    fi
fi

echo "Detected VPS Tailscale IP: $VPS_TAILSCALE_IP"

# -----------------------------
# Configure firewall (UFW)
# -----------------------------
echo "==> Configuring UFW..."
ufw default deny incoming
ufw default allow outgoing

ufw allow from "$VPS_TAILSCALE_IP" to any port 80,443 proto tcp
ufw allow from "$VPS_TAILSCALE_IP" to any port 443 proto udp

ufw --force enable

# -----------------------------
# Setup Traefik
# -----------------------------
TRAEFIK_DIR="${TRAEFIK_DIR:-$HOME/traefik}"
mkdir -p "$TRAEFIK_DIR"
if [[ -d "$PROJECT_ROOT/traefik" ]]; then
    cp -r "$PROJECT_ROOT/traefik/"* "$TRAEFIK_DIR/"
fi
touch "$TRAEFIK_DIR/acme.json"
chmod 600 "$TRAEFIK_DIR/acme.json"

# Create Traefik network for service discovery
echo "==> Creating Traefik network..."
docker network create traefik 2>/dev/null || echo "Network 'traefik' already exists"

# Launch Traefik
if [[ -f "$TRAEFIK_DIR/docker-compose.yml" ]]; then
    echo "==> Starting Traefik..."
    (cd "$TRAEFIK_DIR" && docker-compose up -d --no-recreate)
fi

# -----------------------------
# Setup data directories for services
# -----------------------------
echo "==> Setting up service data directories..."

# Create Nextcloud data directory on large storage if it exists
if [[ -d "/media/data" ]]; then
    echo "==> Creating Nextcloud data directory on /media/data..."
    mkdir -p /media/data/nextcloud
    # Set proper ownership for www-data (UID 33)
    chown -R 33:33 /media/data/nextcloud
    chmod -R 755 /media/data/nextcloud
    echo "Nextcloud data directory created at /media/data/nextcloud"
else
    echo "⚠️  Warning: /media/data not found. Nextcloud will use Docker volumes (limited by OS disk space)"
fi

# -----------------------------
# Launch all service containers
# -----------------------------
SERVICES_PATH="${SERVICES_DIR:-services}"
if [[ -d "$PROJECT_ROOT/$SERVICES_PATH" ]]; then
    echo "==> Launching service containers..."
    for dir in "$PROJECT_ROOT/$SERVICES_PATH"/*; do
        if [[ -d "$dir" && -f "$dir/docker-compose.yml" ]]; then
            echo "==> Deploying $dir..."
            (cd "$dir" && docker-compose pull && docker-compose up -d --no-recreate)
        fi
    done
else
    echo "==> No services directory found at $PROJECT_ROOT/$SERVICES_PATH"
fi

echo "✅ Home PC bootstrap complete!"
echo "All services are running, Traefik is ready, firewall restricted to VPS."
echo ""
echo "📊 Storage Configuration:"
if [[ -d "/media/data/nextcloud" ]]; then
    echo "  ✅ Nextcloud data directory: /media/data/nextcloud"
    echo "  💾 Available space: $(df -h /media/data | awk 'NR==2 {print $4}') free"
else
    echo "  ⚠️  Nextcloud using Docker volumes (OS disk space limited)"
fi
echo ""
echo "🌐 Access Points:"
echo "  • Nextcloud: https://drive.cliff.li"
echo "  • AIO Admin: http://localhost:8080 (home PC only)"
echo "  • Traefik Dashboard: http://localhost:8090 (home PC only)"
