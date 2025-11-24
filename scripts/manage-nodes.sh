#!/usr/bin/env bash
# Node Management Script
# Enhanced version of add-node.sh with additional functionality
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

get_server_ip() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    if [[ -z "$server_ip" ]]; then
        log_error "Could not determine local network IP"
        return 1
    fi

    echo "$server_ip"
}

show_usage() {
    cat << EOF
Node Management Script

Usage: $0 [command] [options]

Commands:
  add [hostname] [--role server|agent]  - Create configuration for new node
  remove [hostname]                     - Remove node from cluster
  list                                  - List all nodes in cluster
  status                                - Show cluster status
  info                                  - Show cluster connection info
  drain [hostname]                      - Drain node for maintenance
  uncordon [hostname]                   - Mark node as schedulable

Options:
  --role server|agent     - Node role (default: agent)

Examples:
  $0 add worker1
  $0 add worker1 --role agent
  $0 add control2 --role server
  $0 remove worker1
  $0 list
  $0 status
  $0 info
  $0 drain worker1

EOF
}

get_cluster_info() {
    log_info "Gathering cluster information"

    # Get server URL (local network IP)
    local server_ip
    server_ip=$(get_server_ip) || return 1

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
    local node_role="${2:-agent}"  # Default to agent if not specified

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    # Validate role
    if [[ "$node_role" != "server" && "$node_role" != "agent" ]]; then
        log_error "Invalid role: $node_role. Must be 'server' or 'agent'"
        return 1
    fi

    # Load configuration
    load_config

    log_step "Creating configuration for node: $node_name (role: $node_role)"

    local node_dir="$HOMELAB_ROOT/nodes/$node_name"
    local template_file="$node_dir/config.env"
    local config_file="$node_dir/config.env.local"

    # Create node directory
    mkdir -p "$node_dir"

    # Get cluster info - use local network IP
    local server_ip
    server_ip=$(get_server_ip) || return 1

    local server_url="https://${server_ip}:6443"
    local cluster_token=""
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
        cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    else
        log_error "Node token not found"
        return 1
    fi

    # Create template file with placeholders
    cat > "$template_file" << EOF
# Homelab Configuration Template for $node_name
# Copy to config.env.local and customize with your secrets

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
NODE_ROLE=$node_role
CLUSTER_TOKEN=REPLACE_WITH_CLUSTER_TOKEN
SERVER_URL=REPLACE_WITH_SERVER_URL

# K3s version
K3S_VERSION="$K3S_VERSION"
KUBECTL_VERSION="$KUBECTL_VERSION"

# =======================
# TAILSCALE CONFIGURATION
# =======================

# Tailscale authentication key
TAILSCALE_AUTHKEY=REPLACE_WITH_YOUR_TAILSCALE_AUTHKEY

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
# ADVANCED CONFIGURATION
# =======================

# UFW firewall configuration
ENABLE_UFW="$ENABLE_UFW"
ALLOW_SSH_FROM_LAN="$ALLOW_SSH_FROM_LAN"
LAN_CIDR="$LAN_CIDR"
EOF

    # Create actual config file with real values
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
NODE_ROLE=$node_role
CLUSTER_TOKEN=$cluster_token
SERVER_URL=$server_url

# K3s version
K3S_VERSION="$K3S_VERSION"
KUBECTL_VERSION="$KUBECTL_VERSION"

# =======================
# TAILSCALE CONFIGURATION
# =======================

# Tailscale authentication key
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY"

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
# ADVANCED CONFIGURATION
# =======================

# UFW firewall configuration
ENABLE_UFW="$ENABLE_UFW"
ALLOW_SSH_FROM_LAN="$ALLOW_SSH_FROM_LAN"
LAN_CIDR="$LAN_CIDR"
EOF

    log_success "Created template file: $template_file"
    log_success "Created config file: $config_file"
    log_info "Template contains placeholders, actual config has real secrets from server"

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

3. **Configuration is ready:**
   \`\`\`bash
   # Config with secrets already created: nodes/$node_name/config.env.local
   # Template available at: nodes/$node_name/config.env
   # No editing needed - secrets copied from server
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
- Node Role: $node_role

## Troubleshooting
- Ensure Tailscale is connected: \`tailscale status\`
- Check K3s logs: \`sudo journalctl -u k3s$([ "$node_role" = "agent" ] && echo "-agent")\`
- Verify network connectivity: \`ping $server_ip\`
EOF

    # Show instructions
    cat << EOF

${GREEN}✅ Node configuration created for $node_name (role: $node_role)${NC}

${BLUE}Configuration created:${NC}
- Template file: $template_file
- Config file: $config_file (with secrets)
- Instructions: $node_dir/README.md
- Role: ${CYAN}$node_role${NC}

${BLUE}To add this node to the cluster:${NC}

1. Copy the homelab directory to the new node:
   scp -r $(dirname "$HOMELAB_ROOT") user@$node_name:~/homelab

2. SSH to the new node and run:
   cd ~/homelab
   # Configuration with secrets already ready at nodes/$node_name/config.env.local
   ./scripts/setup-system.sh
   ./scripts/setup-cluster.sh

3. Verify the node joined:
   ${CYAN}kubectl get nodes${NC}

${BLUE}Current cluster info:${NC}
- Server URL: ${CYAN}$server_url${NC}
- Token: ${CYAN}${cluster_token:0:20}...${NC}
- Node Role: ${CYAN}$node_role${NC}

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
    local node_dir="$HOMELAB_ROOT/nodes/$node_name"
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
    local node_configs_dir="$HOMELAB_ROOT/nodes"
    if [[ -d "$node_configs_dir" ]]; then
        for node_dir in "$node_configs_dir"/*; do
            if [[ -d "$node_dir" ]]; then
                local node_name=$(basename "$node_dir")
                echo "  - $node_name (template: $node_dir/config.env, config: $node_dir/config.env.local)"
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

            # Parse arguments for add command
            local hostname=""
            local role="agent"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --role)
                        role="$2"
                        shift 2
                        ;;
                    *)
                        hostname="$1"
                        shift
                        ;;
                esac
            done

            create_node_config "$hostname" "$role"
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