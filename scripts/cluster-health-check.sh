#!/usr/bin/env bash
# Cluster Health Check Script
# Comprehensive health check for Kubernetes cluster including NFS, storage, and Traefik
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

LOG_FILE="/var/log/cluster-health-check.log"
STATE_FILE="/var/lib/cluster-health-check/state"

# Default configuration
NFS_SERVER="${NFS_SERVER:-192.168.1.94}"
TRAEFIK_HOST="${TRAEFIK_HOST:-traefik.cliff.li}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-5}"

# Metrics counters
NFS_HEALTH_CHECKS=0
STORAGE_HEALTH_CHECKS=0
TRAEFIK_HEALTH_CHECKS=0
CLUSTER_HEALTH_STATUS=1  # 1 = healthy, 0 = degraded

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

error() { log "ERROR: $*"; }
warn()  { log "WARNING: $*"; }
info()  { log "INFO: $*"; }

ensure_directories() {
    sudo mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE" "$STATE_FILE" 2>/dev/null || true
    sudo chmod 644 "$LOG_FILE" "$STATE_FILE" 2>/dev/null || true
}

# Check NFS health
check_nfs_health() {
    info "Checking NFS health..."
    NFS_HEALTH_CHECKS=$((NFS_HEALTH_CHECKS + 1))
    
    # Run the existing NFS health script
    if "$SCRIPT_DIR/monitor-nfs-health.sh" check; then
        info "NFS health check passed"
        return 0
    else
        error "NFS health check failed"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
}

# Check storage health
check_storage_health() {
    info "Checking storage health..."
    STORAGE_HEALTH_CHECKS=$((STORAGE_HEALTH_CHECKS + 1))
    
    # Run the existing storage health script
    if "$SCRIPT_DIR/monitor-storage.sh" check; then
        info "Storage health check passed"
        return 0
    else
        error "Storage health check failed"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
}

# Check Traefik connectivity
check_traefik_health() {
    info "Checking Traefik health..."
    TRAEFIK_HEALTH_CHECKS=$((TRAEFIK_HEALTH_CHECKS + 1))
    
    # Check if Traefik is reachable
    if timeout "$TIMEOUT_SECONDS" curl -f "https://$TRAEFIK_HOST/ping" >/dev/null 2>&1; then
        info "Traefik health check passed"
        return 0
    else
        error "Traefik health check failed"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
}

# Check Kubernetes cluster status
check_kubernetes_status() {
    info "Checking Kubernetes cluster status..."
    
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
    
    # Check if cluster is reachable
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Cannot reach Kubernetes cluster"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
    
    # Check if all nodes are ready
    local nodes_ready
    nodes_ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo 0)
    
    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [[ $nodes_ready -eq $total_nodes ]] && [[ $total_nodes -gt 0 ]]; then
        info "All $total_nodes Kubernetes nodes are ready"
    else
        error "Not all nodes are ready: $nodes_ready/$total_nodes ready"
        CLUSTER_HEALTH_STATUS=0
        return 1
    fi
    
    # Check if core pods are running
    local namespaces=("kube-system" "monitoring" "default")
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            local pods_running
            pods_running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
            local total_pods
            total_pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
            
            if [[ $pods_running -eq $total_pods ]] && [[ $total_pods -gt 0 ]]; then
                info "All $total_pods pods in namespace $ns are running"
            else
                warn "Some pods in namespace $ns are not running: $pods_running/$total_pods"
            fi
        fi
    done
    
    return 0
}

# Export Prometheus metrics
export_cluster_metrics() {
    local timestamp=$(get_timestamp)
    local metrics_content=""
    
    # Overall cluster health status
    metrics_content+=$(export_gauge "cluster_health_status" "$CLUSTER_HEALTH_STATUS" "" "Overall cluster health status (1=healthy, 0=degraded)")
    metrics_content+=$'\n'
    
    # NFS health checks
    metrics_content+=$(export_counter "cluster_nfs_health_checks_total" "$NFS_HEALTH_CHECKS" "" "Total number of NFS health checks")
    metrics_content+=$'\n'
    
    # Storage health checks
    metrics_content+=$(export_counter "cluster_storage_health_checks_total" "$STORAGE_HEALTH_CHECKS" "" "Total number of storage health checks")
    metrics_content+=$'\n'
    
    # Traefik health checks
    metrics_content+=$(export_counter "cluster_traefik_health_checks_total" "$TRAEFIK_HEALTH_CHECKS" "" "Total number of Traefik health checks")
    metrics_content+=$'\n'
    
    # Last run timestamp
    metrics_content+=$(export_gauge "cluster_health_last_run_timestamp_seconds" "$timestamp" "" "Last cluster health check timestamp")
    metrics_content+=$'\n'
    
    # Write metrics to file
    write_metric_file "cluster_health.prom" "$metrics_content"
}

# Main health check
run_cluster_health_check() {
    info "Starting comprehensive cluster health check..."
    
    # Reset status
    CLUSTER_HEALTH_STATUS=1
    
    # Run all health checks
    check_kubernetes_status || true
    check_nfs_health || true
    check_storage_health || true
    check_traefik_health || true
    
    # Update state file
    if [[ $CLUSTER_HEALTH_STATUS -eq 1 ]]; then
        printf 'HEALTHY\n%s\n' "$(date)" | sudo tee "$STATE_FILE" >/dev/null
        info "Cluster health check completed successfully - ALL SYSTEMS OPERATIONAL"
    else
        printf 'DEGRADED\n%s\n' "$(date)" | sudo tee "$STATE_FILE" >/dev/null
        error "Cluster health check completed with errors - SYSTEMS DEGRADED"
    fi
    
    # Export metrics
    export_cluster_metrics
    
    return $CLUSTER_HEALTH_STATUS
}

show_status() {
    echo "=== Cluster Health Status ==="
    
    if [[ -f "$STATE_FILE" ]]; then
        echo "Current State: $(head -1 "$STATE_FILE")"
        echo "Last Check: $(tail -1 "$STATE_FILE")"
    else
        echo "Current State: UNKNOWN (never run)"
    fi
    
    echo ""
    echo "=== Kubernetes Status ==="
    if command -v kubectl >/dev/null 2>&1; then
        echo "Cluster Info:"
        kubectl cluster-info 2>/dev/null | head -3 || echo "Failed to get cluster info"
        
        echo ""
        echo "Node Status:"
        kubectl get nodes -o wide 2>/dev/null || echo "Failed to get node status"
        
        echo ""
        echo "Core Pods Status:"
        kubectl get pods -n kube-system --no-headers 2>/dev/null | head -5 || echo "Failed to get core pods status"
    else
        echo "kubectl not available"
    fi
    
    echo ""
    echo "=== NFS Status ==="
    "$SCRIPT_DIR/monitor-nfs-health.sh" status 2>/dev/null || echo "NFS status check failed"
    
    echo ""
    echo "=== Storage Status ==="
    "$SCRIPT_DIR/monitor-storage.sh" status 2>/dev/null || echo "Storage status check failed"
    
    echo ""
    echo "=== Traefik Status ==="
    if timeout 5 curl -f "https://$TRAEFIK_HOST/ping" >/dev/null 2>&1; then
        echo "Traefik: REACHABLE"
    else
        echo "Traefik: UNREACHABLE"
    fi
    
    echo ""
    echo "=== Recent Log Entries ==="
    if [[ -f "$LOG_FILE" ]]; then
        tail -15 "$LOG_FILE"
    else
        echo "No log file found"
    fi
}

main() {
    case "${1:-check}" in
        check)
            load_config
            ensure_directories
            run_cluster_health_check
            ;;
        status)
            load_config
            show_status
            ;;
        *)
            cat <<EOF
Usage: $0 {check|status}

Commands:
  check    - Run comprehensive cluster health check (default)
  status   - Show current cluster health status

Configuration:
  NFS_SERVER - NFS server IP (default: 192.168.1.94)
  TRAEFIK_HOST - Traefik host (default: traefik.cliff.li)
  TIMEOUT_SECONDS - Timeout for checks in seconds (default: 5)

This script performs a comprehensive health check of the entire cluster,
including NFS mounts, storage systems, Traefik connectivity, and Kubernetes status.
EOF
            exit 1
            ;;
    esac
}

main "$@"
