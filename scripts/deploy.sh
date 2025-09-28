#!/bin/bash
set -euo pipefail

# K3s Deployment Script
# Usage: ./deploy.sh [component] [action]
# Examples:
#   ./deploy.sh infrastructure deploy
#   ./deploy.sh nextcloud deploy
#   ./deploy.sh whoami delete

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/../cluster"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    if ! command -v kustomize &> /dev/null; then
        warn "kustomize not found, using kubectl apply -k instead"
    fi
}

deploy_infrastructure() {
    log "Deploying infrastructure components..."

    # Deploy namespaces first
    kubectl apply -f "$CLUSTER_DIR/manifests/namespaces/"

    # Deploy storage
    kubectl apply -f "$CLUSTER_DIR/manifests/storage/"

    # Wait for storage to be ready
    log "Waiting for storage class to be ready..."
    kubectl wait --for=condition=Ready storageclass/local-storage --timeout=60s || true

    # Deploy Traefik
    kubectl apply -f "$CLUSTER_DIR/manifests/traefik/"

    # Wait for Traefik to be ready
    log "Waiting for Traefik to be ready..."
    kubectl rollout status deployment/traefik -n infrastructure --timeout=300s

    success "Infrastructure deployed successfully"
}

deploy_application() {
    local app_name="$1"
    local app_path=""

    case "$app_name" in
        "whoami")
            app_path="$CLUSTER_DIR/applications/utilities/whoami"
            ;;
        "nextcloud")
            app_path="$CLUSTER_DIR/applications/cloud/nextcloud"
            ;;
        *)
            error "Unknown application: $app_name"
            echo "Available applications: whoami, nextcloud"
            exit 1
            ;;
    esac

    if [[ ! -d "$app_path" ]]; then
        error "Application directory not found: $app_path"
        exit 1
    fi

    log "Deploying $app_name..."

    if command -v kustomize &> /dev/null; then
        kustomize build "$app_path" | kubectl apply -f -
    else
        kubectl apply -k "$app_path"
    fi

    success "$app_name deployed successfully"
}

delete_application() {
    local app_name="$1"
    local app_path=""

    case "$app_name" in
        "whoami")
            app_path="$CLUSTER_DIR/applications/utilities/whoami"
            ;;
        "nextcloud")
            app_path="$CLUSTER_DIR/applications/cloud/nextcloud"
            ;;
        *)
            error "Unknown application: $app_name"
            exit 1
            ;;
    esac

    log "Deleting $app_name..."

    if command -v kustomize &> /dev/null; then
        kustomize build "$app_path" | kubectl delete -f - || true
    else
        kubectl delete -k "$app_path" || true
    fi

    success "$app_name deleted successfully"
}

show_status() {
    log "Cluster Status:"
    kubectl get nodes -o wide

    echo
    log "Infrastructure Status:"
    kubectl get pods -n infrastructure

    echo
    log "Applications Status:"
    kubectl get pods -A --field-selector metadata.namespace!=kube-system,metadata.namespace!=infrastructure

    echo
    log "Ingresses:"
    kubectl get ingress -A
}

show_help() {
    cat << EOF
K3s Deployment Script

Usage: $0 [COMPONENT] [ACTION]

Components:
  infrastructure    Core infrastructure (Traefik, storage, etc.)
  whoami           Simple test service
  nextcloud        Cloud storage platform
  status           Show cluster status

Actions:
  deploy           Deploy the component
  delete           Delete the component
  status           Show component status

Examples:
  $0 infrastructure deploy
  $0 whoami deploy
  $0 nextcloud delete
  $0 status

EOF
}

main() {
    local component="${1:-}"
    local action="${2:-deploy}"

    if [[ -z "$component" ]]; then
        show_help
        exit 1
    fi

    check_prerequisites

    case "$component" in
        "infrastructure")
            case "$action" in
                "deploy")
                    deploy_infrastructure
                    ;;
                *)
                    error "Invalid action for infrastructure: $action"
                    exit 1
                    ;;
            esac
            ;;
        "status")
            show_status
            ;;
        "whoami"|"nextcloud")
            case "$action" in
                "deploy")
                    deploy_application "$component"
                    ;;
                "delete")
                    delete_application "$component"
                    ;;
                *)
                    error "Invalid action: $action"
                    exit 1
                    ;;
            esac
            ;;
        *)
            error "Unknown component: $component"
            show_help
            exit 1
            ;;
    esac
}

main "$@"