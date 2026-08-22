#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

show_usage() {
    cat << EOF
Homelab Management Script

Usage: $0 [command] [options]

${BLUE}Deployment Commands:${NC}
  deploy [component]     - Deploy applications (infrastructure, cloud, media, etc.)
  restart [component]    - Restart applications
  delete [component]     - Delete applications

${BLUE}Management Commands:${NC}
  status                 - Show cluster and service status
  nodes [action]         - Manage cluster nodes (add, remove, list, etc.)
  monitor [action]       - Monitoring operations

${BLUE}Utility Commands:${NC}
  config                 - Show current configuration
  logs [service]         - Show service logs
  shell [service]        - Open shell in service container
  help                   - Show this help message

${BLUE}Examples:${NC}
  $0 deploy                       # Deploy all apps (requires Ansible + K3s first)
  $0 deploy media                 # Deploy media stack
  $0 status                       # Show status
  $0 nodes add worker1            # Add cluster node
  $0 monitor status               # Check monitoring status

${BLUE}Configuration:${NC}
  Create node config: mkdir -p nodes/$(hostname) && cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local

EOF
}

validate_environment() {
    if [[ ! -d "$HOMELAB_ROOT/scripts" ]] || [[ ! -d "$HOMELAB_ROOT/cluster" ]]; then
        log_error "This script must be run from the homelab directory"
        log_error "Current directory: $(pwd)"
        log_error "Expected homelab root: $HOMELAB_ROOT"
        exit 1
    fi

    load_config
}

run_setup_all() {
    log_step "Deploying all applications"

    check_not_root

    log_info "This will deploy all applications (Ansible playbooks + K3s must be set up first)"

    if [[ "${1:-}" != "--yes" ]]; then
        echo ""
        log_warning "This process will:"
        echo "  - Deploy infrastructure (Traefik, storage)"
        echo "  - Deploy all applications (Cloud, Media, etc.)"
        echo "  - Configure monitoring systems"
        echo ""
        echo -n "Continue? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi

    local start_time=$(date +%s)

    "$SCRIPT_DIR/deploy-applications.sh" all deploy

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_formatted=$(printf "%02d:%02d:%02d" $((duration/3600)) $((duration%3600/60)) $((duration%60)))

    cat << EOF

${GREEN}🎉 Homelab setup completed successfully!${NC}

${BLUE}Setup completed in: $duration_formatted${NC}

${BLUE}Your homelab is now ready! 🚀${NC}

${BLUE}Service URLs:${NC}
EOF

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

    cat << EOF

${BLUE}Next steps:${NC}
  1. Configure your services through their web interfaces
  2. Check status: ${CYAN}$0 status${NC}
  3. Monitor storage: ${CYAN}$0 monitor status${NC}

${BLUE}Management:${NC}
  - Add nodes: ${CYAN}$0 nodes add [hostname]${NC}
  - View logs: ${CYAN}$0 logs [service]${NC}

EOF
}

run_deploy() {
    "$SCRIPT_DIR/deploy-applications.sh" "$@"
}

run_nodes() {
    "$SCRIPT_DIR/manage-nodes.sh" "$@"
}

run_monitor() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        "status")
            "$SCRIPT_DIR/monitor-storage.sh" status "$@"
            ;;
        "check")
            "$SCRIPT_DIR/monitor-storage.sh" check "$@"
            ;;
        *)
            log_error "Unknown monitor action: $action"
            echo "Available actions: status, check"
            exit 1
            ;;
    esac
}

show_status() {
    log_step "Homelab Status"

    validate_environment

    echo ""
    log_info "Configuration:"
    echo "  - Domain: ${DOMAIN:-not set}"
    echo "  - User: ${HOMELAB_USER:-not set}"
    echo "  - Node Role: ${NODE_ROLE:-not set}"
    echo "  - Data Root: ${DATA_ROOT:-not set}"

    echo ""
    log_info "System Status:"

    if command_exists docker; then
        echo "  - Docker: ${GREEN}Installed${NC}"
    else
        echo "  - Docker: ${RED}Not installed${NC}"
    fi

    if command_exists kubectl; then
        echo "  - kubectl: ${GREEN}Installed${NC}"
    else
        echo "  - kubectl: ${RED}Not installed${NC}"
    fi

    if command_exists tailscale; then
        echo "  - Tailscale: ${GREEN}Installed${NC}"
        if tailscale status >/dev/null 2>&1; then
            echo "  - Tailscale Status: ${GREEN}Connected${NC}"
        else
            echo "  - Tailscale Status: ${YELLOW}Not connected${NC}"
        fi
    else
        echo "  - Tailscale: ${RED}Not installed${NC}"
    fi

    if check_k3s_running; then
        echo "  - K3s: ${GREEN}Running${NC}"

        echo ""
        log_info "Cluster Status:"
        kubectl get nodes -o wide 2>/dev/null || echo "  Unable to connect to cluster"

        echo ""
        log_info "Applications:"
        "$SCRIPT_DIR/deploy-applications.sh" status 2>/dev/null || echo "  Unable to get application status"
    else
        echo "  - K3s: ${RED}Not running${NC}"
    fi
}

show_config() {
    validate_environment

    log_step "Current Configuration"

    local hostname=$(hostname)
    local node_config="$HOMELAB_ROOT/nodes/$hostname/config.env.local"

    if [[ -f "$node_config" ]]; then
        echo ""
        log_info "Configuration file: $node_config"
        echo ""
        sed 's/\(.*TOKEN.*=\).*/\1***MASKED***/; s/\(.*AUTHKEY.*=\).*/\1***MASKED***/; s/\(.*WEBHOOK.*=\).*/\1***MASKED***/' "$node_config"
    else
        log_warning "Node configuration file not found: $node_config"
        log_info "Create it with: mkdir -p nodes/$hostname && cp config/templates/node-config.env.template nodes/$hostname/config.env.local"
        log_info "Then edit with your values"
    fi
}

show_logs() {
    local service="${1:-}"

    if [[ -z "$service" ]]; then
        log_error "Service name not specified"
        echo "Usage: $0 logs [service-name]"
        echo "Examples: $0 logs jellyfin, $0 logs traefik"
        exit 1
    fi

    validate_environment

    log_info "Showing logs for service: $service"

    local namespaces=("media" "cloud" "infrastructure" "location" "utilities")
    local found=false

    for ns in "${namespaces[@]}"; do
        if kubectl get deployment "$service" -n "$ns" >/dev/null 2>&1; then
            log_info "Found $service in namespace: $ns"
            kubectl logs -f deployment/"$service" -n "$ns"
            found=true
            break
        fi
    done

    if [[ "$found" == "false" ]]; then
        log_error "Service $service not found in any namespace"
        echo ""
        log_info "Available services:"
        for ns in "${namespaces[@]}"; do
            echo "  Namespace $ns:"
            kubectl get deployments -n "$ns" 2>/dev/null | awk 'NR>1 {print "    - " $1}' || echo "    (no deployments)"
        done
    fi
}

open_shell() {
    local service="${1:-}"

    if [[ -z "$service" ]]; then
        log_error "Service name not specified"
        echo "Usage: $0 shell [service-name]"
        exit 1
    fi

    validate_environment

    log_info "Opening shell in service: $service"

    local namespaces=("media" "cloud" "infrastructure" "location" "utilities")
    local found=false

    for ns in "${namespaces[@]}"; do
        if kubectl get deployment "$service" -n "$ns" >/dev/null 2>&1; then
            log_info "Found $service in namespace: $ns"
            kubectl exec -it deployment/"$service" -n "$ns" -- /bin/bash || kubectl exec -it deployment/"$service" -n "$ns" -- /bin/sh
            found=true
            break
        fi
    done

    if [[ "$found" == "false" ]]; then
        log_error "Service $service not found"
    fi
}

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        "setup-all")
            run_setup_all "$@"
            ;;
        "deploy"|"restart"|"delete")
            run_deploy "$command" "$@"
            ;;
        "status")
            show_status
            ;;
        "nodes")
            run_nodes "$@"
            ;;
        "monitor")
            run_monitor "$@"
            ;;
        "config")
            show_config
            ;;
        "logs")
            show_logs "$@"
            ;;
        "shell")
            open_shell "$@"
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi