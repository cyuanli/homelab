#!/usr/bin/env bash
# K3s Cluster Setup Script
# Installs and configures K3s cluster with infrastructure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

main() {
    set_error_handling
    check_not_root

    log_step "Setting up K3s cluster"

    # Load configuration
    load_config

    # Check required variables
    check_required_vars "HOMELAB_USER" "NODE_ROLE"

    log_step "1. Validating prerequisites"
    validate_prerequisites

    log_step "2. Installing K3s"
    install_k3s

    log_step "3. Configuring kubectl access"
    configure_kubectl

    log_step "4. Setting up cluster networking"
    setup_networking

    log_step "5. Deploying core infrastructure"
    deploy_infrastructure

    log_step "6. Validating cluster"
    validate_cluster

    log_success "K3s cluster setup completed successfully!"
    show_cluster_info
}

validate_prerequisites() {
    log_info "Checking system requirements"

    # Check if running on correct user
    if [[ "$(whoami)" != "$HOMELAB_USER" ]]; then
        log_error "This script must be run as user: $HOMELAB_USER"
        exit 1
    fi

    # Check storage directories exist
    local storage_root="${K8S_STORAGE_ROOT:-/opt/k3s-storage}"
    if [[ ! -d "$storage_root" ]]; then
        log_error "Storage root directory not found: $storage_root"
        log_error "Please run setup-system.sh first"
        exit 1
    fi

    # For agent nodes, verify server connection info
    if [[ "${NODE_ROLE}" == "agent" ]]; then
        check_required_vars "SERVER_URL" "CLUSTER_TOKEN"

        # Test connection to server
        local server_host
        server_host=$(echo "$SERVER_URL" | sed 's|https\?://||' | cut -d: -f1)
        if ! ping -c 1 "$server_host" >/dev/null 2>&1; then
            log_warning "Cannot ping K3s server: $server_host"
            log_warning "This may be expected if using Tailscale"
        fi
    fi

    log_success "Prerequisites validated"
}

install_k3s() {
    if check_k3s_running; then
        log_info "K3s is already running"
        return 0
    fi

    local k3s_version="${K3S_VERSION:-v1.28.8+k3s1}"
    log_info "Installing K3s version $k3s_version"

    # Prepare install command
    local install_cmd="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"$k3s_version\" sh -s -"

    if [[ "${NODE_ROLE}" == "server" ]]; then
        log_info "Installing K3s server node"

        # Server-specific options
        local server_opts=(
            "--write-kubeconfig-mode 644"
            "--disable traefik"           # We'll deploy our own
            "--disable servicelb"         # We'll use Traefik
            "--disable local-storage"     # We'll deploy our own
            "--node-name $(hostname)"
        )

        # Add cluster init for first server
        if [[ -z "${CLUSTER_TOKEN:-}" ]]; then
            server_opts+=("--cluster-init")
        fi

        # Add Tailscale external IP if available
        if command_exists tailscale; then
            local tailscale_ip
            if tailscale_ip=$(tailscale ip -4 2>/dev/null); then
                server_opts+=("--node-external-ip $tailscale_ip")
            fi
        fi

        # Add cluster token if provided
        if [[ -n "${CLUSTER_TOKEN:-}" ]]; then
            install_cmd="K3S_TOKEN=\"$CLUSTER_TOKEN\" $install_cmd"
        fi

        # Append server options
        install_cmd="$install_cmd ${server_opts[*]}"

    else
        log_info "Installing K3s agent node"

        # Agent-specific options
        local agent_opts=(
            "--node-name $(hostname)"
        )

        # Add Tailscale external IP if available
        if command_exists tailscale; then
            local tailscale_ip
            if tailscale_ip=$(tailscale ip -4 2>/dev/null); then
                agent_opts+=("--node-external-ip $tailscale_ip")
            fi
        fi

        # Agent requires server URL and token
        install_cmd="K3S_TOKEN=\"$CLUSTER_TOKEN\" $install_cmd agent --server \"$SERVER_URL\" ${agent_opts[*]}"
    fi

    log_info "Running: $install_cmd"
    eval "$install_cmd"

    # Wait for K3s to start
    log_info "Waiting for K3s to start"
    wait_for_condition "systemctl is-active --quiet k3s" 120

    log_success "K3s installed and running"
}

configure_kubectl() {
    if [[ "${NODE_ROLE}" != "server" ]]; then
        log_info "Skipping kubectl configuration for agent node"
        return 0
    fi

    log_info "Configuring kubectl access"

    # Create .kube directory
    mkdir -p "/home/$HOMELAB_USER/.kube"

    # Copy kubeconfig with proper ownership
    sudo cp /etc/rancher/k3s/k3s.yaml "/home/$HOMELAB_USER/.kube/config"
    sudo chown "$HOMELAB_USER:$HOMELAB_USER" "/home/$HOMELAB_USER/.kube/config"

    # Set KUBECONFIG environment variable in bashrc if not already set
    local bashrc="/home/$HOMELAB_USER/.bashrc"
    if ! grep -q "KUBECONFIG" "$bashrc" 2>/dev/null; then
        echo "export KUBECONFIG=/home/$HOMELAB_USER/.kube/config" >> "$bashrc"
    fi

    # Set for current session
    export KUBECONFIG="/home/$HOMELAB_USER/.kube/config"

    # Test kubectl access
    if kubectl get nodes >/dev/null 2>&1; then
        log_success "kubectl configured successfully"
    else
        log_error "kubectl configuration failed"
        return 1
    fi
}

setup_networking() {
    if [[ "${NODE_ROLE}" != "server" ]]; then
        log_info "Skipping networking setup for agent node"
        return 0
    fi

    log_info "Setting up cluster networking"

    # Wait for node to be ready
    log_info "Waiting for node to be ready"
    wait_for_condition "kubectl get nodes --no-headers | awk '{print \$2}' | grep -q Ready" 180

    # Label the node for scheduling
    kubectl label node "$(hostname)" homelab=true --overwrite

    # Create namespaces
    log_info "Creating namespaces"
    kubectl create namespace infrastructure --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace cloud --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace location --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace utilities --dry-run=client -o yaml | kubectl apply -f -

    log_success "Networking configured"
}

deploy_infrastructure() {
    if [[ "${NODE_ROLE}" != "server" ]]; then
        log_info "Skipping infrastructure deployment for agent node"
        return 0
    fi

    log_info "Deploying core infrastructure"

    # Deploy namespaces first (idempotent)
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/namespaces" ]]; then
        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/namespaces/"
    fi

    # Deploy storage
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/storage" ]]; then
        log_info "Deploying storage classes"

        # Update storage manifests with correct node name
        local hostname
        hostname=$(hostname)
        find "$HOMELAB_ROOT/cluster/manifests/storage" -name "*.yaml" -exec sed -i "s/node1/$hostname/g" {} \;

        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/storage/"

        # Wait for storage to be ready
        log_info "Waiting for storage class to be ready"
        wait_for_condition "kubectl get storageclass local-storage >/dev/null 2>&1" 60
    fi

    # Deploy Traefik
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/traefik" ]]; then
        log_info "Deploying Traefik ingress controller"
        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/traefik/"

        # Wait for Traefik to be ready
        log_info "Waiting for Traefik to be ready"
        wait_for_deployment "traefik" "infrastructure"
    fi

    # Deploy cert-manager if available
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/cert-manager" ]]; then
        log_info "Deploying cert-manager"
        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/cert-manager/"
    fi

    log_success "Infrastructure deployed"
}

validate_cluster() {
    log_info "Validating cluster setup"

    # Check if K3s is running
    if ! check_k3s_running; then
        log_error "K3s is not running properly"
        return 1
    fi

    # Check node status
    local node_status
    node_status=$(kubectl get nodes --no-headers | awk '{print $2}')
    if [[ "$node_status" != "Ready" ]]; then
        log_error "Node is not ready: $node_status"
        return 1
    fi

    # For server nodes, check infrastructure
    if [[ "${NODE_ROLE}" == "server" ]]; then
        # Check system pods
        log_info "Checking system pods"
        wait_for_namespace_ready "kube-system"

        # Check infrastructure pods
        log_info "Checking infrastructure pods"
        wait_for_namespace_ready "infrastructure"

        # Test Traefik specifically
        if kubectl get deployment traefik -n infrastructure >/dev/null 2>&1; then
            wait_for_deployment "traefik" "infrastructure"
        fi
    fi

    log_success "Cluster validation completed"
}

show_cluster_info() {
    cat << EOF

${GREEN}✅ K3s cluster setup completed successfully!${NC}

${BLUE}Cluster Information:${NC}
$(kubectl get nodes -o wide)

EOF

    if [[ "${NODE_ROLE}" == "server" ]]; then
        # Show cluster token for adding nodes
        local cluster_token=""
        if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
            cluster_token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
        fi

        local server_url=""
        if command_exists tailscale; then
            local tailscale_ip
            if tailscale_ip=$(tailscale ip -4 2>/dev/null); then
                server_url="https://$tailscale_ip:6443"
            fi
        fi

        cat << EOF
${BLUE}Server Details:${NC}
- Server URL: ${server_url:-https://$(hostname -I | awk '{print $1}'):6443}
- Cluster Token: ${cluster_token:0:20}... (truncated)

${BLUE}To add agent nodes:${NC}
1. Copy homelab repository to new node
2. Update config/homelab.env on new node:
   NODE_ROLE=agent
   SERVER_URL=$server_url
   CLUSTER_TOKEN=$cluster_token
3. Run: ./scripts/setup-system.sh && ./scripts/setup-cluster.sh

EOF
    fi

    cat << EOF
${BLUE}Next steps:${NC}

1. Deploy applications:
   ${CYAN}./scripts/deploy-applications.sh${NC}

2. Check cluster status:
   ${CYAN}kubectl get pods --all-namespaces${NC}

3. Access Traefik dashboard (if deployed):
   ${CYAN}https://traefik.$DOMAIN${NC}

EOF
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi