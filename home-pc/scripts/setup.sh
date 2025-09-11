#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Home PC Bootstrap Script (Production-ready)
# -----------------------------

# Get script directory and home-pc root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEPC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
CONFIG_FILE="$HOMEPC_ROOT/config/home-pc.env.local"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "==> Loading default configuration from $HOMEPC_ROOT/config/home-pc.env"
    source "$HOMEPC_ROOT/config/home-pc.env"
fi

# -----------------------------
# Update system
# -----------------------------
echo "==> Updating system..."
apt update -y && apt upgrade -y

apt install -y curl git ufw jq smartmontools

# -----------------------------
# Install Docker + Compose
# -----------------------------
if ! command -v docker &> /dev/null; then
    echo "==> Installing Docker..."
    curl -fsSL https://get.docker.com | sh
else
    echo "==> Docker already installed, skipping..."
fi
systemctl enable docker
systemctl start docker

if ! command -v docker-compose &> /dev/null; then
    echo "==> Installing latest Docker Compose..."
    DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
    curl -L "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo "==> Docker Compose already installed, skipping..."
fi

# -----------------------------
# Install Tailscale
# -----------------------------
if ! command -v tailscale &> /dev/null; then
    echo "==> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "==> Tailscale already installed, skipping..."
fi

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
ufw allow from "$VPS_TAILSCALE_IP" to any port 22 proto tcp
ufw allow from 192.168.0.0/16 to any port 22 proto tcp

ufw --force enable

# -----------------------------
# Setup Traefik
# -----------------------------
touch "$HOMEPC_ROOT/traefik/acme.json"
chmod 600 "$HOMEPC_ROOT/traefik/acme.json"

# Create Traefik network for service discovery
echo "==> Creating Traefik network..."
docker network create traefik 2>/dev/null || echo "Network 'traefik' already exists"

# Launch Traefik
echo "==> Starting Traefik..."
(cd "$HOMEPC_ROOT/traefik" && docker-compose up -d --no-recreate)

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
echo "==> Launching service containers..."
for dir in "$HOMEPC_ROOT/services"/*; do
    if [[ -d "$dir" && -f "$dir/docker-compose.yml" ]]; then
        echo "==> Deploying $dir..."
        (cd "$dir" && docker-compose pull && docker-compose up -d --no-recreate)
    fi
done

# -----------------------------
# Setup Disk Health Monitoring
# -----------------------------
echo "==> Setting up disk health monitoring..."

# Check if SnapRAID storage is configured
if [[ -d "/media/data" && -f "/etc/snapraid.conf" ]]; then
    echo "==> SnapRAID storage detected, configuring disk health monitoring..."
    
    # Install required packages if not present
    if ! command -v smartctl &> /dev/null; then
        echo "Installing smartmontools for SMART monitoring..."
        apt install -y smartmontools
    fi
    
    # Setup Discord webhook configuration
    MONITOR_CONFIG="$SCRIPT_DIR/disk-monitor.conf"
    if [[ ! -f "$MONITOR_CONFIG" ]]; then
        echo "==> Creating disk monitor configuration..."
        cp "$SCRIPT_DIR/disk-monitor.conf.example" "$MONITOR_CONFIG"
        echo ""
        echo "⚠️  IMPORTANT: Configure Discord webhook for disk failure alerts!"
        echo "   Edit: $MONITOR_CONFIG"
        echo "   Set your Discord webhook URL for storage failure notifications"
        echo ""
    else
        echo "==> Disk monitor configuration already exists"
    fi
    
    # Setup cron job for monitoring
    echo "==> Setting up automated disk health monitoring..."
    CRON_JOB="*/5 * * * * $SCRIPT_DIR/disk-monitor-cron.sh >/dev/null 2>&1"
    
    # Check if cron job already exists
    if ! crontab -l 2>/dev/null | grep -q "disk-monitor-cron.sh"; then
        # Add cron job
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "✅ Disk monitoring cron job added (runs every 5 minutes)"
    else
        echo "✅ Disk monitoring cron job already configured"
    fi
    
    # Test the monitoring system
    echo "==> Testing disk monitoring system..."
    if "$SCRIPT_DIR/disk-monitor.sh" status >/dev/null 2>&1; then
        echo "✅ Disk monitoring system operational"
    else
        echo "⚠️  Warning: Disk monitoring test failed - check configuration"
    fi
    
    echo ""
    echo "🛡️  Storage Protection Configured:"
    echo "  ✅ SMART health monitoring enabled"
    echo "  ✅ Automatic failure detection every 5 minutes"
    echo "  ✅ Emergency service shutdown on drive failure"
    echo "  ✅ Array lockdown (read-only) protection"
    echo "  📱 Discord alerts: Configure webhook in $MONITOR_CONFIG"
    
else
    echo "==> No SnapRAID storage found, skipping disk monitoring setup"
    echo "   (Disk monitoring is designed for SnapRAID + MergerFS arrays)"
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
echo "  • Traefik Dashboard: http://localhost:8080 (home PC only)"
