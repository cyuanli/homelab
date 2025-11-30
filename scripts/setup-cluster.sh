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

# Configure common kubelet arguments for both server and agent nodes
configure_kubelet_args() {
    local -n opts=$1  # nameref to the array to modify

    # Add cluster-wide kubelet memory eviction thresholds
    opts+=("--kubelet-arg=eviction-hard=memory.available<500Mi")
    opts+=("--kubelet-arg=eviction-soft=memory.available<1Gi")
    opts+=("--kubelet-arg=eviction-soft-grace-period=memory.available=1m30s")

    # Add node-specific kubelet resource reservations if configured
    if [[ -n "${KUBELET_SYSTEM_RESERVED_CPU:-}" ]] || [[ -n "${KUBELET_SYSTEM_RESERVED_MEMORY:-}" ]]; then
        local system_reserved=""
        [[ -n "${KUBELET_SYSTEM_RESERVED_CPU:-}" ]] && system_reserved+="cpu=$KUBELET_SYSTEM_RESERVED_CPU"
        [[ -n "${KUBELET_SYSTEM_RESERVED_MEMORY:-}" ]] && {
            [[ -n "$system_reserved" ]] && system_reserved+=","
            system_reserved+="memory=$KUBELET_SYSTEM_RESERVED_MEMORY"
        }
        if [[ -n "$system_reserved" ]]; then
            log_info "Applying system reservation: $system_reserved"
            opts+=("--kubelet-arg=system-reserved=$system_reserved")
        fi
    fi

    if [[ -n "${KUBELET_KUBE_RESERVED_CPU:-}" ]] || [[ -n "${KUBELET_KUBE_RESERVED_MEMORY:-}" ]]; then
        local kube_reserved=""
        [[ -n "${KUBELET_KUBE_RESERVED_CPU:-}" ]] && kube_reserved+="cpu=$KUBELET_KUBE_RESERVED_CPU"
        [[ -n "${KUBELET_KUBE_RESERVED_MEMORY:-}" ]] && {
            [[ -n "$kube_reserved" ]] && kube_reserved+=","
            kube_reserved+="memory=$KUBELET_KUBE_RESERVED_MEMORY"
        }
        if [[ -n "$kube_reserved" ]]; then
            log_info "Applying kube reservation: $kube_reserved"
            opts+=("--kubelet-arg=kube-reserved=$kube_reserved")
        fi
    fi

    # Add CPU manager policy if configured
    if [[ -n "${KUBELET_CPU_MANAGER_POLICY:-}" ]]; then
        log_info "Applying CPU manager policy: $KUBELET_CPU_MANAGER_POLICY"
        opts+=("--kubelet-arg=cpu-manager-policy=$KUBELET_CPU_MANAGER_POLICY")
    fi
}

install_k3s() {
    if check_k3s_running; then
        log_info "K3s is already running"
        return 0
    fi

    local k3s_version="${K3S_VERSION:-v1.33.5+k3s1}"
    log_info "Installing K3s version $k3s_version"

    # Export K3S_TOKEN if provided so the installer can pick it up
    if [[ -n "${CLUSTER_TOKEN:-}" ]]; then
        export K3S_TOKEN="$CLUSTER_TOKEN"
        log_info "K3S_TOKEN exported for installer"
    fi

    # Prepare install command
    local install_cmd="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"$k3s_version\" sh -s -"

    if [[ "${NODE_ROLE}" == "server" ]]; then
        # Server-specific options
        # Each flag and its value must be separate array elements
        local server_opts=(
            "--write-kubeconfig-mode" "644"
            "--disable" "traefik"           # We'll deploy our own
            "--disable" "servicelb"         # We'll use Traefik
            "--disable" "local-storage"     # We'll deploy our own
            "--node-name" "$(hostname)"
        )

        # Configure kubelet arguments common to all nodes
        configure_kubelet_args server_opts

        # Determine if this is first server or joining existing cluster
        if [[ -z "${CLUSTER_TOKEN:-}" ]]; then
            # First server - initialize new cluster
            log_info "Installing K3s server node (first server - initializing cluster)"
            server_opts+=("--cluster-init")
        elif [[ -n "${SERVER_URL:-}" ]]; then
            # Additional control plane node - join existing cluster
            log_info "Installing K3s server node (joining existing cluster at $SERVER_URL)"
            server_opts+=("--server" "$SERVER_URL")
        else
            # Server with token but no URL - still init (fallback)
            log_info "Installing K3s server node (initializing cluster)"
            server_opts+=("--cluster-init")
        fi

        # Add Tailscale external IP if available
        if command_exists tailscale; then
            local tailscale_ip
            if tailscale_ip=$(tailscale ip -4 2>/dev/null); then
                server_opts+=("--node-external-ip" "$tailscale_ip")
            fi
        fi

        # Configure etcd encryption if enabled
        if [[ "${ENABLE_ETCD_ENCRYPTION:-false}" == "true" ]]; then
            setup_etcd_encryption
            server_opts+=("--secrets-encryption")
        fi

        # Append server subcommand and options
        # Use printf %q to properly quote arguments with special characters
        install_cmd="$install_cmd server $(printf '%q ' "${server_opts[@]}")"

    else
        log_info "Installing K3s agent node"

        # Agent-specific options
        # Each flag and its value must be separate array elements
        local agent_opts=(
            "--node-name" "$(hostname)"
        )

        # Configure kubelet arguments common to all nodes
        configure_kubelet_args agent_opts

        # Add Tailscale external IP if available
        if command_exists tailscale; then
            local tailscale_ip
            if tailscale_ip=$(tailscale ip -4 2>/dev/null); then
                agent_opts+=("--node-external-ip" "$tailscale_ip")
            fi
        fi

        # Agent requires server URL and token
        # Use printf %q to properly quote arguments with special characters
        install_cmd="$install_cmd agent --server $(printf '%q' "$SERVER_URL") $(printf '%q ' "${agent_opts[@]}")"
    fi

    log_info "Running: $install_cmd"
    eval "$install_cmd"

    # Wait for K3s to start
    log_info "Waiting for K3s to start"
    if [[ "${NODE_ROLE}" == "server" ]]; then
        wait_for_condition "systemctl is-active --quiet k3s" 120
    else
        wait_for_condition "systemctl is-active --quiet k3s-agent" 120
    fi

    log_success "K3s installed and running"
}

setup_etcd_encryption() {
    log_info "Setting up etcd encryption at rest"

    local encryption_config="/etc/rancher/k3s/encryption-config.yaml"

    # Generate encryption key
    local encryption_key
    encryption_key=$(openssl rand -base64 32)

    # Create encryption config
    sudo mkdir -p "$(dirname "$encryption_config")"
    sudo tee "$encryption_config" > /dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $encryption_key
      - identity: {}
EOF

    sudo chmod 600 "$encryption_config"

    log_success "etcd encryption configured"
    log_warning "Encryption key: $encryption_key"
    log_warning "Save this key securely! Required for disaster recovery"
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

    # Skip for additional control plane nodes joining existing cluster
    if [[ -n "${SERVER_URL:-}" ]]; then
        log_info "Skipping networking setup - joining existing cluster"
        log_info "Only labeling this node"

        # Wait for node to be ready
        log_info "Waiting for node to be ready"
        wait_for_condition "kubectl get nodes --no-headers | grep $(hostname) | awk '{print \$2}' | grep -q Ready" 180

        # Label the node for scheduling
        kubectl label node "$(hostname)" homelab=true --overwrite

        log_success "Node labeled successfully"
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

    # Skip for additional control plane nodes joining existing cluster
    if [[ -n "${SERVER_URL:-}" ]]; then
        log_info "Skipping infrastructure deployment - joining existing cluster"
        log_info "Infrastructure already deployed on the existing control plane"
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

    # Deploy NFS CSI driver if available
    if [[ -d "$HOMELAB_ROOT/cluster/infrastructure/csi-driver-nfs" ]]; then
        log_info "Deploying NFS CSI driver"
        kubectl apply -f "$HOMELAB_ROOT/cluster/infrastructure/csi-driver-nfs/"

        # Wait for CSI driver to be ready
        log_info "Waiting for NFS CSI driver to be ready"
        wait_for_deployment "csi-nfs-controller" "kube-system"

        # Deploy NFS storage class if available
        if [[ -f "$HOMELAB_ROOT/cluster/infrastructure/storage/nfs-storageclass.yaml" ]]; then
            log_info "Deploying NFS storage class"
            kubectl apply -f "$HOMELAB_ROOT/cluster/infrastructure/storage/nfs-storageclass.yaml"
        fi
    fi

    # Deploy Traefik
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/traefik" ]]; then
        log_info "Deploying Traefik ingress controller"

        # Apply all files except IngressRoute (which needs CRDs)
        while IFS= read -r file; do
            [[ -f "$file" ]] && kubectl apply -f "$file"
        done < <(find "$HOMELAB_ROOT/cluster/manifests/traefik/" -name "*.yaml" -exec grep -L "kind: IngressRoute" {} \;)

        # Wait for Traefik to be ready and install CRDs
        log_info "Waiting for Traefik to be ready"
        wait_for_deployment "traefik" "infrastructure"

        # Now apply IngressRoute files (if any)
        while IFS= read -r file; do
            [[ -f "$file" ]] && kubectl apply -f "$file"
        done < <(find "$HOMELAB_ROOT/cluster/manifests/traefik/" -name "*.yaml" -exec grep -l "kind: IngressRoute" {} \;)
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

    # Check node status (only for server nodes that have kubectl configured)
    if [[ "${NODE_ROLE}" == "server" ]]; then
        local node_status
        node_status=$(kubectl get nodes --no-headers | grep $(hostname) | awk '{print $2}')
        if [[ "$node_status" != "Ready" ]]; then
            log_error "Node is not ready: $node_status"
            return 1
        fi
    else
        log_info "Agent node service is active - validation successful"
    fi

    # For first server node only, check infrastructure
    if [[ "${NODE_ROLE}" == "server" && -z "${SERVER_URL:-}" ]]; then
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
    elif [[ "${NODE_ROLE}" == "server" && -n "${SERVER_URL:-}" ]]; then
        log_info "Skipping infrastructure validation - joined existing cluster"
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
2. Update nodes/HOSTNAME/config.env.local on new node:
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