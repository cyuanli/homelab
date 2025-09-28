#!/usr/bin/env bash
# Node Management Script
# Enhanced version of add-node.sh with additional functionality
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

show_usage() {
    cat << EOF
Node Management Script

Usage: $0 [command] [options]

Commands:
  add [hostname]          - Create configuration for new node
  remove [hostname]       - Remove node from cluster
  list                    - List all nodes in cluster
  status                  - Show cluster status
  info                    - Show cluster connection info
  drain [hostname]        - Drain node for maintenance
  uncordon [hostname]     - Mark node as schedulable

Examples:
  $0 add worker1
  $0 remove worker1
  $0 list
  $0 status
  $0 info
  $0 drain worker1

EOF
}

get_cluster_info() {
    log_info "Gathering cluster information"

    # Get server URL (Tailscale IP of current node)
    local server_ip=""
    if command_exists tailscale; then
        server_ip=$(tailscale ip -4 2>/dev/null) || true
    fi

    if [[ -z "$server_ip" ]]; then
        # Fallback to local IP
        server_ip=$(hostname -I | awk '{print $1}')
    fi

    local server_url="https://${server_ip}:6443"

    # Get cluster token
    local cluster_token=""
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
        cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    else
        log_error "Node token not found. Is this a K3s server node?"
        return 1
    fi

    echo "SERVER_URL=$server_url"
    echo "CLUSTER_TOKEN=$cluster_token"
    echo "SERVER_IP=$server_ip"
}

create_node_config() {
    local node_name="$1"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    # Load configuration
    load_config

    log_step "Creating configuration for node: $node_name"

    local node_dir="$HOMELAB_ROOT/config/node-configs/$node_name"
    local config_file="$node_dir/config.env"

    # Create node directory
    mkdir -p "$node_dir"

    # Get cluster info
    local server_ip=""
    if command_exists tailscale; then
        server_ip=$(tailscale ip -4 2>/dev/null) || true
    fi

    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I | awk '{print $1}')
    fi

    local server_url="https://${server_ip}:6443"
    local cluster_token=""
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
        cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    else
        log_error "Node token not found"
        return 1
    fi

    # Create config file based on main config
    cat > "$config_file" << EOF
# Homelab Configuration for $node_name
# Based on main homelab configuration

# =======================
# BASIC CONFIGURATION
# =======================

# Domain and networking
DOMAIN="$DOMAIN"
ACME_EMAIL="$ACME_EMAIL"

# User configuration
HOMELAB_USER="$HOMELAB_USER"
HOMELAB_UID="$HOMELAB_UID"
HOMELAB_GID="$HOMELAB_GID"

# =======================
# K3S CONFIGURATION
# =======================

# Node role and cluster info
NODE_ROLE=agent
CLUSTER_TOKEN=$cluster_token
SERVER_URL=$server_url

# K3s version
K3S_VERSION="$K3S_VERSION"
KUBECTL_VERSION="$KUBECTL_VERSION"

# =======================
# TAILSCALE CONFIGURATION
# =======================

# Tailscale authentication key (REPLACE WITH YOUR OWN)
TAILSCALE_AUTHKEY="REPLACE_WITH_YOUR_TAILSCALE_AUTHKEY"

# =======================
# STORAGE CONFIGURATION
# =======================

# Storage configuration (inherited from main cluster)
DATA_ROOT="$DATA_ROOT"
K8S_STORAGE_ROOT="$K8S_STORAGE_ROOT"

# =======================
# SERVICE CONFIGURATION
# =======================

# Container user/group IDs
PUID="$PUID"
PGID="$PGID"
TIMEZONE="$TIMEZONE"

# Feature flags
ENABLE_TRAEFIK_DASHBOARD="false"
ENABLE_LOCATION_SERVICES="$ENABLE_LOCATION_SERVICES"
ENABLE_DISK_MONITORING="$ENABLE_DISK_MONITORING"
ENABLE_BACKUP_MONITORING="$ENABLE_BACKUP_MONITORING"

# =======================
# MONITORING & NOTIFICATIONS
# =======================

# Discord webhook (inherited)
DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"

# =======================
# ADVANCED CONFIGURATION
# =======================

# UFW firewall configuration
ENABLE_UFW="$ENABLE_UFW"
ALLOW_SSH_FROM_LAN="$ALLOW_SSH_FROM_LAN"
LAN_CIDR="$LAN_CIDR"
EOF

    log_success "Created config file: $config_file"
    log_warning "Please update TAILSCALE_AUTHKEY in the config file"

    # Create setup instructions
    cat > "$node_dir/README.md" << EOF
# Node Setup Instructions for $node_name

## Prerequisites
- Fresh Debian-based system
- Network connectivity to this server
- Tailscale auth key

## Setup Steps

1. **Copy homelab repository to new node:**
   \`\`\`bash
   scp -r $(dirname "$HOMELAB_ROOT") user@$node_name:~/homelab
   \`\`\`

2. **SSH to the new node:**
   \`\`\`bash
   ssh user@$node_name
   cd ~/homelab
   \`\`\`

3. **Update configuration:**
   \`\`\`bash
   # Copy the node-specific config
   cp config/node-configs/$node_name/config.env config/homelab.env

   # Edit and set your Tailscale auth key
   vim config/homelab.env
   \`\`\`

4. **Run setup scripts:**
   \`\`\`bash
   # System setup
   ./scripts/setup-system.sh

   # Cluster join
   ./scripts/setup-cluster.sh
   \`\`\`

5. **Verify node joined:**
   \`\`\`bash
   # On server node:
   kubectl get nodes
   \`\`\`

## Configuration Details
- Server URL: $server_url
- Cluster Token: ${cluster_token:0:20}... (truncated)
- Node Role: agent

## Troubleshooting
- Ensure Tailscale is connected: \`tailscale status\`
- Check K3s logs: \`sudo journalctl -u k3s-agent\`
- Verify network connectivity: \`ping $server_ip\`
EOF

    # Show instructions
    cat << EOF

${GREEN}✅ Node configuration created for $node_name${NC}

${BLUE}Configuration created:${NC}
- Config file: $config_file
- Instructions: $node_dir/README.md

${BLUE}To add this node to the cluster:${NC}

1. Update the Tailscale auth key:
   ${CYAN}vim $config_file${NC}

2. Copy the homelab directory to the new node:
   ${CYAN}scp -r $(dirname "$HOMELAB_ROOT") user@$node_name:~/homelab${NC}

3. SSH to the new node and run:
   ${CYAN}cd ~/homelab
   cp config/node-configs/$node_name/config.env config/homelab.env
   vim config/homelab.env  # Set TAILSCALE_AUTHKEY
   ./scripts/setup-system.sh
   ./scripts/setup-cluster.sh${NC}

4. Verify the node joined:
   ${CYAN}kubectl get nodes${NC}

${BLUE}Current cluster info:${NC}
- Server URL: ${CYAN}$server_url${NC}
- Token: ${CYAN}${cluster_token:0:20}...${NC}

EOF
}

remove_node() {
    local node_name="$1"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    load_config

    log_step "Removing node: $node_name"

    # Check if node exists in cluster
    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        log_warning "Node $node_name not found in cluster"
        return 0
    fi

    # Drain the node first
    log_info "Draining node: $node_name"
    kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force

    # Delete the node
    log_info "Deleting node: $node_name"
    kubectl delete node "$node_name"

    # Remove node configuration
    local node_dir="$HOMELAB_ROOT/config/node-configs/$node_name"
    if [[ -d "$node_dir" ]]; then
        log_info "Removing node configuration: $node_dir"
        rm -rf "$node_dir"
    fi

    log_success "Node $node_name removed from cluster"
}

list_nodes() {
    load_config

    log_step "Cluster Nodes"
    kubectl get nodes -o wide

    echo ""
    log_info "Node configurations:"
    local node_configs_dir="$HOMELAB_ROOT/config/node-configs"
    if [[ -d "$node_configs_dir" ]]; then
        for node_dir in "$node_configs_dir"/*; do
            if [[ -d "$node_dir" ]]; then
                local node_name=$(basename "$node_dir")
                echo "  - $node_name (config: $node_dir/config.env)"
            fi
        done
    else
        echo "  No node configurations found"
    fi
}

show_status() {
    load_config

    log_step "Cluster Status"

    echo ""
    log_info "Nodes:"
    kubectl get nodes -o wide

    echo ""
    log_info "Cluster Info:"
    kubectl cluster-info

    echo ""
    log_info "Resource Usage:"
    kubectl top nodes 2>/dev/null || log_info "Metrics not available"

    echo ""
    log_info "System Pods:"
    kubectl get pods -n kube-system

    echo ""
    log_info "Workload Distribution:"
    kubectl get pods -A -o wide | grep -v "kube-system" | head -20
}

drain_node() {
    local node_name="$1"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    load_config

    log_step "Draining node: $node_name"

    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        log_error "Node $node_name not found in cluster"
        return 1
    fi

    kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data

    log_success "Node $node_name drained successfully"
}

uncordon_node() {
    local node_name="$1"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    load_config

    log_step "Uncordoning node: $node_name"

    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        log_error "Node $node_name not found in cluster"
        return 1
    fi

    kubectl uncordon "$node_name"

    log_success "Node $node_name is now schedulable"
}

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        "add")
            # Check if we're on a K3s server node
            if [[ ! -f /var/lib/rancher/k3s/server/node-token ]]; then
                log_error "This command must be run on a K3s server node"
                exit 1
            fi
            create_node_config "${1:-}"
            ;;
        "remove")
            remove_node "${1:-}"
            ;;
        "list")
            list_nodes
            ;;
        "status")
            show_status
            ;;
        "info")
            if [[ ! -f /var/lib/rancher/k3s/server/node-token ]]; then
                log_error "This command must be run on a K3s server node"
                exit 1
            fi
            get_cluster_info
            ;;
        "drain")
            drain_node "${1:-}"
            ;;
        "uncordon")
            uncordon_node "${1:-}"
            ;;
        "")
            log_error "No command specified"
            show_usage
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi