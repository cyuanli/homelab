#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

USE_TAILSCALE=false

# Default-route source IP, not `hostname -I` order (docker/tailscale IPs can come first).
get_server_ip() {
    local server_ip
    if $USE_TAILSCALE; then
        server_ip=$(tailscale ip -4)
    else
        server_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
    fi

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
  add [hostname] [--role server|agent] [--tailscale]
                                        - Create configuration for new node
  remove [hostname] [--purge]           - Remove node from cluster
  list                                  - List all nodes in cluster
  status                                - Show cluster status
  info [--tailscale]                    - Show cluster connection info
  drain [hostname]                      - Drain node for maintenance
  uncordon [hostname]                   - Mark node as schedulable

Options:
  --role server|agent     - Node role (default: agent)
  --tailscale             - Use this host's Tailscale IP (for nodes off the LAN)
  --purge                 - Also delete nodes/<hostname>/ (incl. gitignored config.env.local)

Examples:
  $0 add worker1
  $0 add worker1 --role agent
  $0 add control2 --role server
  $0 add cyl-mitx --tailscale
  $0 remove worker1
  $0 list
  $0 status
  $0 info
  $0 drain worker1

EOF
}

get_cluster_info() {
    log_info "Gathering cluster information"

    local server_ip
    server_ip=$(get_server_ip) || return 1
    local server_url="https://${server_ip}:6443"

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
    local node_role="${2:-agent}"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    if [[ "$node_role" != "server" && "$node_role" != "agent" ]]; then
        log_error "Invalid role: $node_role. Must be 'server' or 'agent'"
        return 1
    fi

    load_config

    log_step "Creating configuration for node: $node_name (role: $node_role)"

    local node_dir="$HOMELAB_ROOT/nodes/$node_name"
    local template_file="$node_dir/config.env"
    local config_file="$node_dir/config.env.local"

    mkdir -p "$node_dir"

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

    export NODE_NAME="$node_name"
    export NODE_ROLE="$node_role"
    envsubst < "$HOMELAB_ROOT/config/templates/node-config.env.template" > "$template_file"

    cp "$template_file" "$config_file"
    sed -i "s|REPLACE_WITH_CLUSTER_TOKEN|$cluster_token|g" "$config_file"
    sed -i "s|REPLACE_WITH_SERVER_URL|$server_url|g" "$config_file"
    sed -i "s|REPLACE_WITH_YOUR_TAILSCALE_AUTHKEY|$TAILSCALE_AUTHKEY|g" "$config_file"

    log_success "Created template file: $template_file"
    log_success "Created config file: $config_file"
    log_info "Template contains placeholders, actual config has real secrets from server"

    local labels_file="$node_dir/labels.yaml"
    if [[ ! -f "$labels_file" ]]; then
        cat > "$labels_file" << EOF
# cpu-tier high = 8+ cores, memory-tier high = 16GB+
apiVersion: v1
kind: Node
metadata:
  name: $node_name
  labels:
    homelab/cpu-tier: low
    homelab/memory-tier: low
EOF

        log_success "Created labels file: $labels_file"
        log_info "Remember to update labels.yaml with actual node specs (cpu-tier: high/low, memory-tier: high/low)"
    fi

    if [[ -n "$HOMELAB_USER" ]]; then
        chown -R "$HOMELAB_USER:$HOMELAB_USER" "$node_dir"
        log_success "Set ownership of $node_dir to $HOMELAB_USER:$HOMELAB_USER"
    fi

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

4. **Run Ansible setup** (see docs/INSTALLATION.md):
   \`\`\`bash
   cd ansible && ansible-playbook site.yml --ask-become-pass --limit $node_name
   \`\`\`

5. **Verify node joined:**
   \`\`\`bash
   # On server node:
   kubectl get nodes
   \`\`\`

6. **Apply node labels (after verifying hardware specs):**
   \`\`\`bash
   # Edit labels.yaml to match actual node specs
   # Then apply:
   kubectl apply -f nodes/$node_name/labels.yaml
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
   # Add node to ansible/inventory.yml, then run Ansible setup (see docs/INSTALLATION.md)
   cd ansible && ansible-playbook site.yml --ask-become-pass --limit $node_name

3. Verify the node joined:
   ${CYAN}kubectl get nodes${NC}

${BLUE}Current cluster info:${NC}
- Server URL: ${CYAN}$server_url${NC}
- Token: ${CYAN}${cluster_token:0:20}...${NC}
- Node Role: ${CYAN}$node_role${NC}

EOF
}

# Etcd servers: kubectl delete node makes k3s remove the etcd member (managed-etcd-controller).
remove_node() {
    local node_name="$1"
    local purge="${2:-false}"

    if [[ -z "$node_name" ]]; then
        log_error "Node hostname not provided"
        show_usage
        return 1
    fi

    load_config

    log_step "Removing node: $node_name"

    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        log_warning "Node $node_name not found in cluster"
        return 0
    fi

    local etcd_label is_etcd=false
    etcd_label=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/etcd}')
    [[ "$etcd_label" == true ]] && is_etcd=true

    if $is_etcd; then
        local etcd_nodes remaining not_ready
        etcd_nodes=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers)
        remaining=$(( $(wc -l <<<"$etcd_nodes") - 1 ))
        log_info "$node_name is an etcd member ($remaining members after removal)"
        if (( remaining < 3 || remaining % 2 == 0 )); then
            log_error "Removing it leaves $remaining etcd members (need an odd number >= 3). Add a server first."
            return 1
        fi
        not_ready=$(awk -v n="$node_name" '$1 != n && $2 != "Ready" {print $1}' <<<"$etcd_nodes")
        if [[ -n "$not_ready" ]]; then
            log_error "Other etcd members not Ready: $not_ready. Refusing to shrink etcd."
            return 1
        fi
    fi

    log_info "Draining node: $node_name"
    kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s

    if $is_etcd; then
        local ready
        ready=$(kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        if [[ "$ready" == "True" ]]; then
            log_error "k3s still runs on $node_name. Run 'sudo systemctl stop k3s' there, wait for NotReady, then re-run."
            return 1
        fi
    fi

    log_info "Deleting node: $node_name"
    kubectl delete node "$node_name" --timeout=120s

    $is_etcd && log_info "Verify etcd member removal on any server: sudo journalctl -u k3s --since -10min | grep -i 'removing etcd member'"

    local node_dir="$HOMELAB_ROOT/nodes/$node_name"
    if [[ "$purge" == "true" && -d "$node_dir" ]]; then
        log_info "Removing node configuration: $node_dir"
        rm -rf "$node_dir"
    elif [[ -d "$node_dir" ]]; then
        log_info "Kept $node_dir (pass --purge to delete it)"
    fi

    log_success "Node $node_name removed from cluster"
    log_info "Before uninstalling k3s on it: scripts/pre-uninstall-check.sh $node_name"
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
            if [[ ! -f /var/lib/rancher/k3s/server/node-token ]]; then
                log_error "This command must be run on a K3s server node"
                exit 1
            fi

            local hostname=""
            local role="agent"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --role)
                        role="$2"
                        shift 2
                        ;;
                    --tailscale)
                        USE_TAILSCALE=true
                        shift
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
            local purge=false
            [[ "${2:-}" == --purge ]] && purge=true
            remove_node "${1:-}" "$purge"
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
            [[ "${1:-}" == --tailscale ]] && USE_TAILSCALE=true
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi