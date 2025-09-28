#!/bin/bash
set -euo pipefail

# K3s Installation Script for Homelab
# This script sets up K3s with Tailscale networking

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../nodes/$(hostname)/config.env"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Config file not found: $CONFIG_FILE"
    echo "Please create it with the following variables:"
    echo "  NODE_ROLE=server|agent"
    echo "  CLUSTER_TOKEN=your-secret-token"
    echo "  SERVER_URL=https://first-server-ip:6443 (for agents only)"
    echo "  TAILSCALE_AUTHKEY=your-tailscale-key"
    exit 1
fi

# Ensure Tailscale is installed and connected
install_tailscale() {
    if ! command -v tailscale &> /dev/null; then
        echo "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    if ! tailscale status &> /dev/null; then
        echo "Connecting to Tailscale..."
        sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-routes
    fi
}

# Install K3s
install_k3s() {
    local install_cmd="curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="

    if [[ "$NODE_ROLE" == "server" ]]; then
        echo "Installing K3s server..."
        install_cmd+="'server --cluster-init --disable traefik --node-external-ip $(tailscale ip -4)'"

        if [[ -n "${CLUSTER_TOKEN:-}" ]]; then
            install_cmd=" K3S_TOKEN=$CLUSTER_TOKEN $install_cmd"
        fi
    else
        echo "Installing K3s agent..."
        if [[ -z "${SERVER_URL:-}" ]]; then
            echo "SERVER_URL must be set for agent nodes"
            exit 1
        fi
        install_cmd+="'agent --server $SERVER_URL --node-external-ip $(tailscale ip -4)'"
        install_cmd=" K3S_TOKEN=$CLUSTER_TOKEN $install_cmd"
    fi

    eval "$install_cmd"
}

# Configure kubectl
setup_kubectl() {
    if [[ "$NODE_ROLE" == "server" ]]; then
        mkdir -p ~/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown $(id -u):$(id -g) ~/.kube/config

        echo "K3s server installed successfully!"
        echo "To join other nodes, use:"
        echo "  NODE_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)"
        echo "  SERVER_URL=https://$(tailscale ip -4):6443"
    fi
}

# Main execution
main() {
    echo "Starting K3s installation on $(hostname)..."

    install_tailscale
    install_k3s
    setup_kubectl

    echo "Installation complete!"
    kubectl get nodes
}

main "$@"