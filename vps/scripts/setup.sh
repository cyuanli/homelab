#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# VPS Bootstrap Script
# -----------------------------

# Get script directory and vps root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
CONFIG_FILE="$VPS_ROOT/config/vps.env.local"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "==> Loading default configuration from $VPS_ROOT/config/vps.env"
    source "$VPS_ROOT/config/vps.env"
fi
echo "==> Updating system..."
apt update -y && apt upgrade -y

echo "==> Installing prerequisites..."
apt install -y nginx-full ufw curl jq

# -----------------------------
# Install Tailscale
# -----------------------------
if ! command -v tailscale &> /dev/null; then
    echo "==> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "==> Tailscale already installed, skipping..."
fi

echo "==> Starting Tailscale login..."
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale up --authkey="$TAILSCALE_AUTHKEY"
else
    echo "No TAILSCALE_AUTHKEY provided, manual authentication required:"
    tailscale up
fi

# -----------------------------
# Detect Home PC Tailscale IPs
# -----------------------------

echo "==> Detecting home PC Tailscale IPs..."

# Support both HOME_PC_NAMES (multiple) and HOME_PC_NAME (single, legacy)
if [[ -n "${HOME_PC_NAMES:-}" ]]; then
    PC_NAMES="$HOME_PC_NAMES"
elif [[ -n "${HOME_PC_NAME:-}" ]]; then
    PC_NAMES="$HOME_PC_NAME"
else
    echo "ERROR: Neither HOME_PC_NAMES nor HOME_PC_NAME is set."
    exit 1
fi

# Detect IPs for all specified PCs
declare -a PC_IPS
for pc_name in $PC_NAMES; do
    echo "  - Looking up $pc_name..."
    pc_ip=$(tailscale status --json | jq -r ".Peer[] | select(.HostName==\"$pc_name\") | .Addresses[0]")

    if [[ -z "$pc_ip" ]]; then
        echo "WARNING: $pc_name not found on Tailscale, skipping."
        continue
    fi

    echo "  - Found $pc_name: $pc_ip"
    PC_IPS+=("$pc_ip")
done

if [[ ${#PC_IPS[@]} -eq 0 ]]; then
    echo "ERROR: No home PCs found on Tailscale."
    exit 1
fi

echo "Detected ${#PC_IPS[@]} home PC(s) on Tailscale"

# -----------------------------
# Generate upstream blocks
# -----------------------------

echo "==> Generating upstream configurations..."

# Generate server lines for each IP
UPSTREAM_HTTPS=""
UPSTREAM_HTTP3=""
UPSTREAM_HTTP=""
UPSTREAM_SSH=""

for ip in "${PC_IPS[@]}"; do
    UPSTREAM_HTTPS+="    server $ip:443 max_fails=2 fail_timeout=5s;\n"
    UPSTREAM_HTTP3+="    server $ip:443 max_fails=2 fail_timeout=5s;\n"
    UPSTREAM_HTTP+="    server $ip:80 max_fails=2 fail_timeout=5s;\n"
done

# SSH uses only the first backend (no load balancing needed)
UPSTREAM_SSH="    server ${PC_IPS[0]}:22;"

# -----------------------------
# Deploy and generate Nginx config
# -----------------------------
TEMPLATE_FILE="/etc/nginx/nginx.conf.template"
NGINX_CONF="/etc/nginx/nginx.conf"
SOURCE_TEMPLATE="$VPS_ROOT/nginx/nginx.conf.template"

echo "==> Deploying nginx template..."
if [[ ! -f "$SOURCE_TEMPLATE" ]]; then
    echo "ERROR: Source nginx template $SOURCE_TEMPLATE not found."
    exit 1
fi

cp "$SOURCE_TEMPLATE" "$TEMPLATE_FILE"

echo "==> Generating Nginx configuration..."
# Replace placeholders with upstream blocks
sed -e "s|{{UPSTREAM_HTTPS}}|$UPSTREAM_HTTPS|g" \
    -e "s|{{UPSTREAM_HTTP3}}|$UPSTREAM_HTTP3|g" \
    -e "s|{{UPSTREAM_HTTP}}|$UPSTREAM_HTTP|g" \
    -e "s|{{UPSTREAM_SSH}}|$UPSTREAM_SSH|g" \
    "$TEMPLATE_FILE" > "$NGINX_CONF"

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
