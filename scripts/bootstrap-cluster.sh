#!/bin/bash
set -euo pipefail

# K3s Cluster Bootstrap Script
# This script sets up a complete K3s cluster with all infrastructure

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

check_requirements() {
    log "Checking requirements..."

    # Check if running as non-root
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root"
        exit 1
    fi

    # Check if config exists
    local hostname=$(hostname)
    local config_file_local="$HOMELAB_DIR/nodes/$hostname/config.env.local"
    local config_file_template="$HOMELAB_DIR/nodes/$hostname/config.env"
    local config_file=""

    if [[ -f "$config_file_local" ]]; then
        config_file="$config_file_local"
    elif [[ -f "$config_file_template" ]]; then
        config_file="$config_file_template"
    else
        error "Config file not found: $config_file_local or $config_file_template"
        echo "Please create it with:"
        echo "  NODE_ROLE=server|agent"
        echo "  CLUSTER_TOKEN=your-secret-token"
        echo "  TAILSCALE_AUTHKEY=your-tailscale-key"
        echo "  SERVER_URL=https://first-server-ip:6443 (for agents only)"
        exit 1
    fi

    # Check if directories exist
    if [[ ! -d "$HOMELAB_DIR/cluster" ]]; then
        error "Cluster directory not found: $HOMELAB_DIR/cluster"
        exit 1
    fi

    success "Requirements check passed"
}

setup_storage_directories() {
    log "Setting up storage directories..."

    # Create directories for persistent volumes
    sudo mkdir -p /opt/k3s-storage/{traefik-acme,nextcloud-data,nextcloud-files,postgres-data,redis-data}
    sudo chown -R $USER:$USER /opt/k3s-storage

    success "Storage directories created"
}

install_k3s() {
    log "Installing K3s..."

    # Use the bootstrap script
    "$HOMELAB_DIR/cluster/bootstrap/k3s-install.sh"

    # Wait for node to be ready
    log "Waiting for node to be ready..."
    kubectl wait --for=condition=Ready node/$(hostname) --timeout=300s

    success "K3s installation completed"
}

deploy_infrastructure() {
    log "Deploying infrastructure..."

    # Update storage manifests with correct node name
    local hostname=$(hostname)
    sed -i "s/node1/$hostname/g" "$HOMELAB_DIR/cluster/manifests/storage/local-storage.yaml"

    # Deploy using the deploy script
    "$SCRIPT_DIR/deploy.sh" infrastructure deploy

    success "Infrastructure deployment completed"
}

verify_deployment() {
    log "Verifying deployment..."

    # Check if all pods are running
    kubectl get pods -A

    # Check Traefik specifically
    kubectl rollout status deployment/traefik -n infrastructure --timeout=300s

    # Show ingresses
    kubectl get ingress -A

    success "Deployment verification completed"
}

show_next_steps() {
    cat << EOF

${GREEN}✅ K3s Cluster Bootstrap Complete!${NC}

Next steps:

1. Deploy your first application:
   ${BLUE}./scripts/deploy.sh whoami deploy${NC}

2. Check the deployment:
   ${BLUE}./scripts/deploy.sh status${NC}

3. Access Traefik dashboard:
   ${BLUE}https://traefik.cliff.li${NC}

4. To add more nodes:
   ${BLUE}# On new nodes, update their config.env.local with:
   NODE_ROLE=agent
   SERVER_URL=https://$(tailscale ip -4 2>/dev/null || echo "TAILSCALE_IP"):6443
   CLUSTER_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "TOKEN_FROM_SERVER")${NC}

5. Deploy Nextcloud:
   ${BLUE}# Update secrets first:
   vim cluster/applications/cloud/nextcloud/secrets.yaml
   ./scripts/deploy.sh nextcloud deploy${NC}

Useful commands:
- ${BLUE}kubectl get nodes${NC} - View cluster nodes
- ${BLUE}kubectl get pods -A${NC} - View all pods
- ${BLUE}kubectl logs -n infrastructure deployment/traefik${NC} - View Traefik logs

EOF
}

main() {
    log "Starting K3s cluster bootstrap..."

    check_requirements
    setup_storage_directories
    install_k3s
    deploy_infrastructure
    verify_deployment
    show_next_steps

    success "Bootstrap completed successfully!"
}

main "$@"