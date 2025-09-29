#!/bin/bash
set -euo pipefail

# Add Node to K3s Cluster Script
# Usage: ./add-node.sh [node-hostname]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$SCRIPT_DIR/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

get_cluster_info() {
    log "Gathering cluster information..."

    # Get server URL (Tailscale IP of current node)
    local server_ip
    if command -v tailscale &> /dev/null; then
        server_ip=$(tailscale ip -4)
    else
        error "Tailscale not found. Please install Tailscale first."
        exit 1
    fi

    local server_url="https://${server_ip}:6443"

    # Get cluster token
    local cluster_token
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
        cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    else
        error "Node token not found. Is this a K3s server node?"
        exit 1
    fi

    echo "SERVER_URL=$server_url"
    echo "CLUSTER_TOKEN=$cluster_token"
}

create_node_config() {
    local node_name="${1:-}"

    if [[ -z "$node_name" ]]; then
        error "Node hostname not provided"
        echo "Usage: $0 [node-hostname]"
        exit 1
    fi

    local node_dir="$HOMELAB_DIR/nodes/$node_name"
    local template_file="$node_dir/config.env"
    local config_file="$node_dir/config.env.local"

    # Create node directory
    mkdir -p "$node_dir"

    # Get cluster info
    log "Getting cluster information..."
    local server_ip
    if command -v tailscale &> /dev/null; then
        server_ip=$(tailscale ip -4)
    else
        error "Tailscale not found"
        exit 1
    fi

    local server_url="https://${server_ip}:6443"
    local cluster_token
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
        cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    else
        error "Node token not found"
        exit 1
    fi

    # Create template file
    cat > "$template_file" << EOF
# K3s Node Configuration Template for $node_name
NODE_ROLE=agent
CLUSTER_TOKEN=REPLACE_WITH_CLUSTER_TOKEN
SERVER_URL=REPLACE_WITH_SERVER_URL
TAILSCALE_AUTHKEY=REPLACE_WITH_YOUR_TAILSCALE_AUTHKEY
EOF

    # Create config file with actual values
    cat > "$config_file" << EOF
# K3s Node Configuration for $node_name
NODE_ROLE=agent
CLUSTER_TOKEN=$cluster_token
SERVER_URL=$server_url
TAILSCALE_AUTHKEY=REPLACE_WITH_YOUR_TAILSCALE_AUTHKEY
EOF

    success "Created template file: $template_file"
    success "Created config file: $config_file"
    warn "Please update TAILSCALE_AUTHKEY in the config file"

    # Create setup script for the new node
    cat > "$node_dir/setup-node.sh" << EOF
#!/bin/bash
set -euo pipefail

# Setup script for $node_name
# Run this script on the new node

echo "Setting up $node_name as K3s agent node..."

# Copy this directory to the new node
# scp -r $(dirname "$config_file") user@$node_name:~/homelab/nodes/

# On the new node, run:
# cd ~/homelab
# ./cluster/bootstrap/k3s-install.sh

echo "Node setup completed!"
EOF

    chmod +x "$node_dir/setup-node.sh"

    # Show instructions
    cat << EOF

${GREEN}✅ Node configuration created for $node_name${NC}

To add this node to the cluster:

1. Update the Tailscale auth key:
   ${BLUE}vim $config_file${NC}

2. Copy the homelab directory to the new node:
   ${BLUE}scp -r $(dirname "$HOMELAB_DIR") user@$node_name:~/homelab${NC}

3. SSH to the new node and run:
   ${BLUE}cd ~/homelab
   ./cluster/bootstrap/k3s-install.sh${NC}

4. Verify the node joined:
   ${BLUE}kubectl get nodes${NC}

Current cluster info:
- Server URL: ${BLUE}$server_url${NC}
- Token: ${BLUE}${cluster_token:0:20}...${NC}

EOF
}

show_cluster_status() {
    log "Current cluster status:"
    kubectl get nodes -o wide
}

main() {
    local node_name="${1:-}"

    if [[ -z "$node_name" ]]; then
        if [[ "${1:-}" == "--info" ]]; then
            get_cluster_info
            exit 0
        fi

        error "Node hostname not provided"
        echo "Usage: $0 [node-hostname]"
        echo "       $0 --info (to get cluster info only)"
        exit 1
    fi

    # Check if we're on a K3s server node
    if [[ ! -f /var/lib/rancher/k3s/server/node-token ]]; then
        error "This script must be run on a K3s server node"
        exit 1
    fi

    create_node_config "$node_name"
    show_cluster_status
}

main "$@"