#!/usr/bin/env bash
# Application Deployment Script
# Deploys applications to K3s cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

show_usage() {
    cat << EOF
Application Deployment Script

Usage: $0 [component] [action]

Components:
  infrastructure  - Core infrastructure (Traefik, storage, etc.)
  cloud          - Cloud services (Nextcloud)
  media          - Media stack (Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin)
  location       - Location services (Owntracks)
  utilities      - Utility services (whoami, monitoring)
  all            - Deploy all components
  status         - Show cluster status

Actions:
  deploy         - Deploy the component (default)
  delete         - Delete the component
  restart        - Restart the component

Examples:
  $0 infrastructure deploy
  $0 media deploy
  $0 cloud delete
  $0 all deploy
  $0 status

EOF
}

check_prerequisites() {
    # Check if running on correct system
    load_config

    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please ensure K3s is running and kubectl is configured"
        exit 1
    fi

    if ! command_exists envsubst; then
        log_error "envsubst is not installed"
        log_error "Install with: sudo apt install gettext-base"
        exit 1
    fi
}

deploy_infrastructure() {
    log_step "Deploying infrastructure components"

    # Deploy namespaces first
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/namespaces" ]]; then
        log_info "Deploying namespaces"
        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/namespaces/"
    fi

    # Deploy storage
    if [[ -d "$HOMELAB_ROOT/cluster/manifests/storage" ]]; then
        log_info "Deploying storage classes"
        kubectl apply -f "$HOMELAB_ROOT/cluster/manifests/storage/"

        # Wait for storage class to be ready
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

    log_success "Infrastructure deployed successfully"
}

deploy_cloud() {
    log_step "Deploying cloud services"

    local app_path="$HOMELAB_ROOT/cluster/applications/cloud/nextcloud"

    if [[ ! -d "$app_path" ]]; then
        log_error "Nextcloud application directory not found: $app_path"
        return 1
    fi

    log_info "Deploying Nextcloud"
    kubectl apply -k "$app_path"

    # Wait for deployments to be ready
    wait_for_deployment "redis" "cloud"
    wait_for_deployment "nextcloud" "cloud"

    log_success "Cloud services deployed successfully"
}

deploy_media() {
    log_step "Deploying media stack"

    local app_path="$HOMELAB_ROOT/cluster/applications/media-stack"

    if [[ ! -d "$app_path" ]]; then
        log_error "Media stack application directory not found: $app_path"
        return 1
    fi

    log_info "Deploying media stack (Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin)"
    kubectl apply -k "$app_path"

    # Wait for all media deployments to be ready
    local services=("prowlarr" "sonarr" "radarr" "qbittorrent" "jellyfin")
    for service in "${services[@]}"; do
        log_info "Waiting for $service to be ready"
        wait_for_deployment "$service" "media"
    done

    log_success "Media stack deployed successfully"
}

deploy_location() {
    log_step "Deploying location services"

    if [[ "${ENABLE_LOCATION_SERVICES:-false}" != "true" ]]; then
        log_info "Location services disabled in configuration, skipping"
        return 0
    fi

    local app_path="$HOMELAB_ROOT/cluster/applications/location"

    if [[ ! -d "$app_path" ]]; then
        log_warning "Location services directory not found: $app_path"
        return 0
    fi

    log_info "Deploying Owntracks"
    kubectl apply -k "$app_path"

    wait_for_deployment "owntracks" "location"

    log_success "Location services deployed successfully"
}

deploy_utilities() {
    log_step "Deploying utility services"

    local utilities_path="$HOMELAB_ROOT/cluster/applications/utilities"

    if [[ -d "$utilities_path" ]]; then
        log_info "Deploying utility services"

        # Deploy each utility subdirectory
        for utility_dir in "$utilities_path"/*; do
            if [[ -d "$utility_dir" && -f "$utility_dir/kustomization.yaml" ]]; then
                local utility_name=$(basename "$utility_dir")
                log_info "Deploying utility: $utility_name"
                kubectl apply -k "$utility_dir"
            fi
        done

        wait_for_namespace_ready "utilities"
    else
        log_info "No utilities directory found, skipping"
    fi

    log_success "Utility services deployed successfully"
}

delete_component() {
    local component="$1"

    case "$component" in
        "infrastructure")
            log_info "Deleting infrastructure components"
            if [[ -d "$HOMELAB_ROOT/cluster/manifests/traefik" ]]; then
                kubectl delete -f "$HOMELAB_ROOT/cluster/manifests/traefik/" || true
            fi
            if [[ -d "$HOMELAB_ROOT/cluster/manifests/storage" ]]; then
                kubectl delete -f "$HOMELAB_ROOT/cluster/manifests/storage/" || true
            fi
            ;;
        "cloud")
            log_info "Deleting cloud services"
            local app_path="$HOMELAB_ROOT/cluster/applications/cloud/nextcloud"
            if [[ -d "$app_path" ]]; then
                kubectl delete -k "$app_path" || true
            fi
            ;;
        "media")
            log_info "Deleting media stack"
            local app_path="$HOMELAB_ROOT/cluster/applications/media-stack"
            if [[ -d "$app_path" ]]; then
                kubectl delete -k "$app_path" || true
            fi
            ;;
        "location")
            log_info "Deleting location services"
            local app_path="$HOMELAB_ROOT/cluster/applications/location"
            if [[ -d "$app_path" ]]; then
                kubectl delete -k "$app_path" || true
            fi
            ;;
        "utilities")
            log_info "Deleting utility services"
            local utilities_path="$HOMELAB_ROOT/cluster/applications/utilities"
            if [[ -d "$utilities_path" ]]; then
                for utility_dir in "$utilities_path"/*; do
                    if [[ -d "$utility_dir" ]]; then
                        kubectl delete -k "$utility_dir" || true
                    fi
                done
            fi
            ;;
        *)
            log_error "Unknown component: $component"
            return 1
            ;;
    esac

    log_success "$component deleted successfully"
}

restart_component() {
    local component="$1"

    case "$component" in
        "infrastructure")
            log_info "Restarting infrastructure components"
            kubectl rollout restart deployment/traefik -n infrastructure || true
            ;;
        "cloud")
            log_info "Restarting cloud services"
            kubectl rollout restart deployment/redis -n cloud || true
            kubectl rollout restart deployment/nextcloud -n cloud || true
            ;;
        "media")
            log_info "Restarting media stack"
            local services=("prowlarr" "sonarr" "radarr" "qbittorrent" "jellyfin")
            for service in "${services[@]}"; do
                kubectl rollout restart deployment/"$service" -n media || true
            done
            ;;
        "location")
            log_info "Restarting location services"
            kubectl rollout restart deployment/owntracks -n location || true
            ;;
        "utilities")
            log_info "Restarting utility services"
            kubectl rollout restart deployment --all -n utilities || true
            ;;
        *)
            log_error "Unknown component: $component"
            return 1
            ;;
    esac

    log_success "$component restarted successfully"
}

show_status() {
    log_step "Cluster Status"

    echo ""
    log_info "Nodes:"
    kubectl get nodes -o wide

    echo ""
    log_info "Infrastructure Status:"
    kubectl get pods -n infrastructure 2>/dev/null || echo "No infrastructure namespace"

    echo ""
    log_info "Cloud Services Status:"
    kubectl get pods -n cloud 2>/dev/null || echo "No cloud namespace"

    echo ""
    log_info "Media Stack Status:"
    kubectl get pods -n media 2>/dev/null || echo "No media namespace"

    echo ""
    log_info "Location Services Status:"
    kubectl get pods -n location 2>/dev/null || echo "No location namespace"

    echo ""
    log_info "Utility Services Status:"
    kubectl get pods -n utilities 2>/dev/null || echo "No utilities namespace"

    echo ""
    log_info "Ingresses:"
    kubectl get ingress -A 2>/dev/null || echo "No ingresses found"

    echo ""
    log_info "Service URLs (if accessible):"
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "  - Traefik Dashboard: https://traefik.$DOMAIN"
        echo "  - Nextcloud: https://nextcloud.$DOMAIN"
        echo "  - qBittorrent: https://qbittorrent.$DOMAIN"
        echo "  - Prowlarr: https://prowlarr.$DOMAIN"
        echo "  - Sonarr: https://sonarr.$DOMAIN"
        echo "  - Radarr: https://radarr.$DOMAIN"
        echo "  - Jellyfin: https://jellyfin.$DOMAIN"
        if [[ "${ENABLE_LOCATION_SERVICES:-false}" == "true" ]]; then
            echo "  - Owntracks: https://owntracks.$DOMAIN"
        fi
    fi
}

deploy_all() {
    log_step "Deploying all components"

    deploy_infrastructure
    deploy_cloud
    deploy_media

    if [[ "${ENABLE_LOCATION_SERVICES:-false}" == "true" ]]; then
        deploy_location
    fi

    deploy_utilities

    log_success "All components deployed successfully"
}

main() {
    local component="${1:-}"
    local action="${2:-deploy}"

    if [[ -z "$component" ]]; then
        show_usage
        exit 1
    fi

    check_prerequisites

    case "$component" in
        "infrastructure"|"cloud"|"media"|"location"|"utilities")
            case "$action" in
                "deploy")
                    deploy_"$component"
                    ;;
                "delete")
                    delete_component "$component"
                    ;;
                "restart")
                    restart_component "$component"
                    ;;
                *)
                    log_error "Invalid action: $action"
                    show_usage
                    exit 1
                    ;;
            esac
            ;;
        "all")
            case "$action" in
                "deploy")
                    deploy_all
                    ;;
                *)
                    log_error "Only 'deploy' action is supported for 'all'"
                    exit 1
                    ;;
            esac
            ;;
        "status")
            show_status
            ;;
        *)
            log_error "Unknown component: $component"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi