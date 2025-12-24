#!/usr/bin/env bash
# NFS Mount Health Monitor
# Detects and recovers from stale NFS mounts in Kubernetes
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

LOG_FILE="/var/log/nfs-health-monitor.log"
STATE_FILE="/var/lib/nfs-monitor/state"
NFS_SERVER="${NFS_SERVER:-192.168.1.94}"
TIMEOUT_SECONDS="${NFS_MOUNT_TIMEOUT:-5}"

# Metrics
STALE_MOUNTS_DETECTED=0
RECOVERY_ATTEMPTS=0
RECOVERY_SUCCESSES=0

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

# Check if NFS server is reachable
check_nfs_server() {
    info "Checking NFS server connectivity: $NFS_SERVER"

    if timeout "$TIMEOUT_SECONDS" bash -c "echo >/dev/tcp/$NFS_SERVER/2049" 2>/dev/null; then
        info "NFS server $NFS_SERVER is reachable on port 2049"
        return 0
    else
        error "NFS server $NFS_SERVER is NOT reachable on port 2049"
        return 1
    fi
}

# Detect stale NFS mounts by checking kubelet pod volumes
check_for_stale_mounts() {
    local stale_found=0
    local mount_paths=()

    info "Scanning for stale NFS mounts in kubelet volumes..."

    # Find all NFS CSI mounts
    while IFS= read -r mount_path; do
        if [[ -n "$mount_path" ]]; then
            mount_paths+=("$mount_path")
        fi
    done < <(find /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/*/mount -type d 2>/dev/null || true)

    if [[ ${#mount_paths[@]} -eq 0 ]]; then
        warn "No NFS CSI mounts found"
        return 0
    fi

    info "Found ${#mount_paths[@]} NFS CSI mount points to check"

    for mount_path in "${mount_paths[@]}"; do
        # Quick stat check with timeout
        if ! timeout "$TIMEOUT_SECONDS" stat "$mount_path" >/dev/null 2>&1; then
            error "STALE MOUNT DETECTED: $mount_path"
            stale_found=$((stale_found + 1))
            STALE_MOUNTS_DETECTED=$((STALE_MOUNTS_DETECTED + 1))
        else
            info "Mount OK: $mount_path"
        fi
    done

    if [[ $stale_found -gt 0 ]]; then
        error "Found $stale_found stale NFS mounts"
        return 1
    else
        info "All NFS mounts are healthy"
        return 0
    fi
}

# Restart CSI driver to force remount
restart_csi_driver() {
    info "Restarting NFS CSI driver pods to force remount..."
    RECOVERY_ATTEMPTS=$((RECOVERY_ATTEMPTS + 1))

    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found, cannot restart CSI driver"
        return 1
    fi

    # Delete CSI node driver pods (they'll be recreated by DaemonSet)
    info "Deleting CSI node driver pods..."
    if kubectl delete pods -n kube-system -l app=csi-nfs-node --grace-period=30 2>&1 | tee -a "$LOG_FILE"; then
        info "CSI node driver pods deleted"
    else
        error "Failed to delete CSI node driver pods"
        return 1
    fi

    # Wait for pods to be recreated
    info "Waiting for CSI driver pods to restart..."
    sleep 10

    if kubectl wait --for=condition=ready pods -n kube-system -l app=csi-nfs-node --timeout=120s 2>&1 | tee -a "$LOG_FILE"; then
        info "CSI driver pods restarted successfully"
        RECOVERY_SUCCESSES=$((RECOVERY_SUCCESSES + 1))
        return 0
    else
        error "CSI driver pods failed to become ready"
        return 1
    fi
}

# Restart pods with stale mounts
restart_affected_pods() {
    info "Looking for pods with potential stale NFS mounts..."

    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found"
        return 1
    fi

    # Get all pods using NFS PVCs
    local pods_to_restart=()

    # Find pods in media and cloud namespaces (most likely to use NFS)
    for ns in media cloud monitoring games; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            while IFS= read -r pod; do
                if [[ -n "$pod" ]]; then
                    # Check if pod has NFS volumes
                    if kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim}' 2>/dev/null | grep -q .; then
                        info "Found pod with PVC in namespace $ns: $pod"
                        pods_to_restart+=("$ns/$pod")
                    fi
                fi
            done < <(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
        fi
    done

    if [[ ${#pods_to_restart[@]} -eq 0 ]]; then
        warn "No pods found with NFS volumes"
        return 0
    fi

    info "Found ${#pods_to_restart[@]} pods with NFS volumes"

    # Restart each pod
    for pod_ref in "${pods_to_restart[@]}"; do
        local ns="${pod_ref%/*}"
        local pod="${pod_ref#*/}"

        info "Deleting pod $ns/$pod to force remount..."
        if kubectl delete pod -n "$ns" "$pod" --grace-period=30 2>&1 | tee -a "$LOG_FILE"; then
            info "Pod $ns/$pod deleted successfully"
        else
            warn "Failed to delete pod $ns/$pod"
        fi
    done

    info "Waiting for pods to restart..."
    sleep 15

    return 0
}

# Export Prometheus metrics
export_nfs_metrics() {
    local nfs_server_ok="$1"
    local stale_mounts_ok="$2"
    local overall_status="$3"

    local timestamp=$(get_timestamp)
    local metrics_content=""

    # Overall NFS health status
    metrics_content+=$(export_gauge "nfs_health_status" "$overall_status" 'type="overall"' "Overall NFS health status (1=healthy, 0=degraded)")
    metrics_content+=$'\n'

    # NFS server connectivity
    metrics_content+=$(export_gauge "nfs_server_reachable" "$nfs_server_ok" "server=\"$NFS_SERVER\"" "NFS server reachability (1=ok, 0=down)")
    metrics_content+=$'\n'

    # Stale mounts status
    metrics_content+=$(export_gauge "nfs_mounts_healthy" "$stale_mounts_ok" "" "NFS mount health (1=ok, 0=stale mounts detected)")
    metrics_content+=$'\n'

    # Counters
    metrics_content+=$(export_counter "nfs_stale_mounts_detected_total" "$STALE_MOUNTS_DETECTED" "" "Total number of stale NFS mounts detected")
    metrics_content+=$'\n'

    metrics_content+=$(export_counter "nfs_recovery_attempts_total" "$RECOVERY_ATTEMPTS" "" "Total number of recovery attempts")
    metrics_content+=$'\n'

    metrics_content+=$(export_counter "nfs_recovery_successes_total" "$RECOVERY_SUCCESSES" "" "Total number of successful recoveries")
    metrics_content+=$'\n'

    # Last run timestamp
    metrics_content+=$(export_gauge "nfs_monitor_last_run_timestamp_seconds" "$timestamp" "" "Last NFS health check timestamp")
    metrics_content+=$'\n'

    # Write metrics to file
    write_metric_file "nfs_health.prom" "$metrics_content"
}

# Main health check
run_health_check() {
    info "Starting NFS health check..."

    local nfs_server_ok=0
    local stale_mounts_ok=0
    local overall_status=0
    local needs_recovery=false

    # Check NFS server connectivity
    if check_nfs_server; then
        nfs_server_ok=1
    else
        warn "NFS server is not reachable, skipping mount checks"
        export_nfs_metrics "$nfs_server_ok" "$stale_mounts_ok" "$overall_status"
        return 1
    fi

    # Check for stale mounts
    if check_for_stale_mounts; then
        stale_mounts_ok=1
        overall_status=1
    else
        warn "Stale mounts detected, recovery needed"
        needs_recovery=true
        stale_mounts_ok=0
        overall_status=0
    fi

    # Attempt recovery if needed
    if [[ "$needs_recovery" == "true" ]]; then
        warn "Initiating automatic recovery..."

        # Try restarting CSI driver first
        if restart_csi_driver; then
            info "CSI driver restarted, waiting for remount..."
            sleep 10

            # Re-check mounts
            if check_for_stale_mounts; then
                info "Recovery successful - mounts are now healthy"
                stale_mounts_ok=1
                overall_status=1
            else
                warn "CSI restart didn't fix stale mounts, restarting affected pods..."
                restart_affected_pods

                # Final check
                sleep 10
                if check_for_stale_mounts; then
                    info "Recovery successful after pod restart"
                    stale_mounts_ok=1
                    overall_status=1
                else
                    error "Recovery failed - manual intervention required"
                fi
            fi
        else
            error "Failed to restart CSI driver"
        fi
    fi

    # Update state file
    if [[ $overall_status -eq 1 ]]; then
        printf 'HEALTHY\n%s\n' "$(date)" | sudo tee "$STATE_FILE" >/dev/null
    else
        printf 'DEGRADED\n%s\n' "$(date)" | sudo tee "$STATE_FILE" >/dev/null
    fi

    # Export metrics
    export_nfs_metrics "$nfs_server_ok" "$stale_mounts_ok" "$overall_status"

    if [[ $overall_status -eq 1 ]]; then
        info "NFS health check completed successfully"
        return 0
    else
        error "NFS health check completed with errors"
        return 1
    fi
}

show_status() {
    echo "=== NFS Health Monitor Status ==="

    if [[ -f "$STATE_FILE" ]]; then
        echo "Current State: $(head -1 "$STATE_FILE")"
        echo "Last Check: $(tail -1 "$STATE_FILE")"
    else
        echo "Current State: UNKNOWN (never run)"
    fi

    echo ""
    echo "=== NFS Server ==="
    if check_nfs_server; then
        echo "Server: REACHABLE"
    else
        echo "Server: UNREACHABLE"
    fi

    echo ""
    echo "=== NFS Mounts ==="
    local mount_count=0
    while IFS= read -r mount_path; do
        if [[ -n "$mount_path" ]]; then
            mount_count=$((mount_count + 1))
            if timeout 2 stat "$mount_path" >/dev/null 2>&1; then
                echo "✓ $mount_path"
            else
                echo "✗ $mount_path (STALE)"
            fi
        fi
    done < <(find /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/*/mount -type d 2>/dev/null || true)

    if [[ $mount_count -eq 0 ]]; then
        echo "No NFS CSI mounts found"
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
            run_health_check
            ;;
        status)
            load_config
            show_status
            ;;
        recover)
            load_config
            ensure_directories
            info "Manual recovery initiated..."
            restart_csi_driver
            sleep 10
            restart_affected_pods
            ;;
        *)
            cat <<EOF
Usage: $0 {check|status|recover}

Commands:
  check    - Run NFS health check and auto-recovery (default)
  status   - Show current NFS health status
  recover  - Manually trigger recovery (restart CSI driver and affected pods)

Configuration:
  NFS_SERVER - NFS server IP (default: 192.168.1.94)
  NFS_MOUNT_TIMEOUT - Timeout for mount checks in seconds (default: 5)

This script should be run periodically via cron to ensure NFS mount health.
EOF
            exit 1
            ;;
    esac
}

main "$@"
