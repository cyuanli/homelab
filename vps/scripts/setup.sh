#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# VPS Bootstrap Script
# -----------------------------

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
CONFIG_FILE="$PROJECT_ROOT/config/vps.env.local"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "==> Loading default configuration from $PROJECT_ROOT/config/vps.env"
    source "$PROJECT_ROOT/config/vps.env"
fi
echo "==> Updating system..."
apt update -y && apt upgrade -y

echo "==> Installing prerequisites..."
apt install -y nginx-full ufw curl jq

# -----------------------------
# Install Tailscale
# -----------------------------
echo "==> Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "==> Starting Tailscale login..."
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale up --authkey="$TAILSCALE_AUTHKEY"
else
    echo "No TAILSCALE_AUTHKEY provided, manual authentication required:"
    tailscale up
fi

# -----------------------------
# Detect Home PC Tailscale IP
# -----------------------------

echo "==> Detecting home PC Tailscale IP..."
HOME_PC_IP=$(tailscale status --json | jq -r ".Peer[] | select(.HostName==\"$HOME_PC_NAME\") | .Addresses[0]")

if [[ -z "$HOME_PC_IP" ]]; then
    echo "ERROR: Home PC not found on Tailscale."
    exit 1
fi

echo "Detected home PC Tailscale IP: $HOME_PC_IP"

# -----------------------------
# Deploy and generate Nginx config
# -----------------------------
TEMPLATE_FILE="/etc/nginx/nginx.conf.template"
NGINX_CONF="/etc/nginx/nginx.conf"
SOURCE_TEMPLATE="$PROJECT_ROOT/${NGINX_TEMPLATE_PATH:-nginx/nginx.conf.template}"

echo "==> Deploying nginx template..."
if [[ ! -f "$SOURCE_TEMPLATE" ]]; then
    echo "ERROR: Source nginx template $SOURCE_TEMPLATE not found."
    exit 1
fi

cp "$SOURCE_TEMPLATE" "$TEMPLATE_FILE"

echo "==> Generating Nginx configuration..."
sed "s/{{HOME_PC_IP}}/$HOME_PC_IP/g" "$TEMPLATE_FILE" > "$NGINX_CONF"

# -----------------------------
# Configure UFW
# -----------------------------
echo "==> Configuring firewall (UFW)..."

# Define ports and protocols
declare -A PORTS
PORTS=(
  [22]="tcp"
  [80]="tcp"
  [443]="tcp"
  [443_udp]="udp"
  [51422]="tcp"
)

# Apply rules
for port in "${!PORTS[@]}"; do
    proto="${PORTS[$port]}"
    # Convert key for UDP naming
    portnum="${port/_udp/}"
    ufw allow "$portnum/$proto"
done

ufw --force enable

# -----------------------------
# Enable and start Nginx
# -----------------------------
echo "==> Testing Nginx configuration..."
nginx -t

echo "==> Enabling and starting Nginx..."
systemctl enable nginx
systemctl restart nginx

# -----------------------------
# Configure SSH key access
# -----------------------------
echo "==> Configuring SSH key access..."

if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    VPS_PUBLIC_KEY="$SSH_PUBLIC_KEY"
    echo "Using SSH key from configuration file"
else
    read -rp "Paste the public SSH key you want to authorize on the VPS: " VPS_PUBLIC_KEY
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$VPS_PUBLIC_KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Disable password authentication for root
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Restart SSH
systemctl restart sshd

echo "✅ SSH key installed and password login disabled."

echo "==> VPS bootstrap complete!"
echo "You can now access your home PC services via the VPS."
