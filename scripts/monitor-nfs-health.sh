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

# Set KUBECONFIG for kubectl when running as root via sudo/systemd
# Uses HOMELAB_USER from config if available, otherwise defaults to 'cyl'
setup_kubeconfig() {
    local user="${HOMELAB_USER:-cyl}"
    local kubeconfig="/home/${user}/.kube/config"
    if [[ -f "$kubeconfig" ]]; then
        export KUBECONFIG="$kubeconfig"
    fi
}

# Metrics
STALE_MOUNTS_DETECTED=0
RECOVERY_ATTEMPTS=0
RECOVERY_SUCCESSES=0

# Global array to track stale mount paths for recovery
STALE_MOUNT_PATHS=()

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

    # Reset global stale mounts array
    STALE_MOUNT_PATHS=()

    info "Scanning for stale NFS mounts in kubelet volumes..."

    # Use mount command to find NFS mounts - this reads /proc/mounts and doesn't
    # require accessing the mount point (which would hang/fail on stale mounts)
    while IFS= read -r mount_path; do
        if [[ -n "$mount_path" ]]; then
            mount_paths+=("$mount_path")
        fi
    done < <(mount -t nfs,nfs4 | grep '/var/lib/kubelet/pods/.*/volumes/kubernetes.io~csi/' | awk '{print $3}')

    if [[ ${#mount_paths[@]} -eq 0 ]]; then
        warn "No NFS CSI mounts found"
        return 0
    fi

    info "Found ${#mount_paths[@]} NFS CSI mount points to check"

    for mount_path in "${mount_paths[@]}"; do
        # Quick stat check with timeout - detects stale mounts and missing directories
        if ! timeout "$TIMEOUT_SECONDS" stat "$mount_path" >/dev/null 2>&1; then
            error "STALE MOUNT DETECTED: $mount_path"
            stale_found=$((stale_found + 1))
            STALE_MOUNTS_DETECTED=$((STALE_MOUNTS_DETECTED + 1))
            STALE_MOUNT_PATHS+=("$mount_path")
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

# Lazy unmount stale mounts
# This detaches the mount immediately, allowing the directory to be removed
unmount_stale_mounts() {
    if [[ ${#STALE_MOUNT_PATHS[@]} -eq 0 ]]; then
        info "No stale mounts to unmount"
        return 0
    fi

    info "Unmounting ${#STALE_MOUNT_PATHS[@]} stale NFS mounts..."
    RECOVERY_ATTEMPTS=$((RECOVERY_ATTEMPTS + 1))

    local unmount_failed=0
    for mount_path in "${STALE_MOUNT_PATHS[@]}"; do
        info "Lazy unmounting: $mount_path"
        if sudo umount -l "$mount_path" 2>&1 | tee -a "$LOG_FILE"; then
            info "Successfully unmounted: $mount_path"
        else
            error "Failed to unmount: $mount_path"
            unmount_failed=$((unmount_failed + 1))
        fi
    done

    if [[ $unmount_failed -eq 0 ]]; then
        RECOVERY_SUCCESSES=$((RECOVERY_SUCCESSES + 1))
        return 0
    else
        return 1
    fi
}

# Extract pod UID from mount path
# Path format: /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<volume>/mount
get_pod_uid_from_mount() {
    local mount_path="$1"
    echo "$mount_path" | sed -n 's|/var/lib/kubelet/pods/\([^/]*\)/.*|\1|p'
}

# Restart only pods that have stale mounts
restart_affected_pods() {
    if [[ ${#STALE_MOUNT_PATHS[@]} -eq 0 ]]; then
        info "No stale mounts, no pods to restart"
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found"
        return 1
    fi

    # Get unique pod UIDs from stale mount paths
    local pod_uids=()
    for mount_path in "${STALE_MOUNT_PATHS[@]}"; do
        local uid
        uid=$(get_pod_uid_from_mount "$mount_path")
        if [[ -n "$uid" ]]; then
            # Check if already in array
            local found=false
            for existing in "${pod_uids[@]:-}"; do
                if [[ "$existing" == "$uid" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                pod_uids+=("$uid")
            fi
        fi
    done

    if [[ ${#pod_uids[@]} -eq 0 ]]; then
        warn "Could not extract pod UIDs from stale mount paths"
        return 1
    fi

    info "Found ${#pod_uids[@]} pods with stale mounts"

    # Find and delete pods by UID
    for pod_uid in "${pod_uids[@]}"; do
        info "Looking for pod with UID: $pod_uid"

        # Search all namespaces for the pod
        local pod_info
        pod_info=$(kubectl get pods -A -o jsonpath="{range .items[?(@.metadata.uid=='$pod_uid')]}{.metadata.namespace}/{.metadata.name}{end}" 2>/dev/null)

        if [[ -n "$pod_info" ]]; then
            local ns="${pod_info%/*}"
            local pod="${pod_info#*/}"
            info "Deleting pod $ns/$pod (UID: $pod_uid) to force fresh mount..."
            if kubectl delete pod -n "$ns" "$pod" --grace-period=10 --force 2>&1 | tee -a "$LOG_FILE"; then
                info "Pod $ns/$pod deleted successfully"
            else
                warn "Failed to delete pod $ns/$pod"
            fi
        else
            info "Pod with UID $pod_uid not found (may have been deleted already)"
        fi
    done

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

        # Step 1: Lazy unmount stale mounts
        if unmount_stale_mounts; then
            info "Stale mounts unmounted successfully"
        else
            warn "Some mounts failed to unmount"
        fi

        # Step 2: Restart only the affected pods (they'll get fresh mounts)
        restart_affected_pods

        # Wait for pods to restart
        info "Waiting for pods to restart with fresh mounts..."
        sleep 15

        # Final check
        if check_for_stale_mounts; then
            info "Recovery successful - all mounts are now healthy"
            stale_mounts_ok=1
            overall_status=1
        else
            error "Recovery failed - manual intervention required"
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
    done < <(mount -t nfs,nfs4 | grep '/var/lib/kubelet/pods/.*/volumes/kubernetes.io~csi/' | awk '{print $3}')

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
            setup_kubeconfig
            ensure_directories
            run_health_check
            ;;
        status)
            load_config
            setup_kubeconfig
            show_status
            ;;
        recover)
            load_config
            setup_kubeconfig
            ensure_directories
            info "Manual recovery initiated..."
            # First detect stale mounts to populate STALE_MOUNT_PATHS
            check_for_stale_mounts || true
            if [[ ${#STALE_MOUNT_PATHS[@]} -gt 0 ]]; then
                unmount_stale_mounts
                restart_affected_pods
                sleep 10
                check_for_stale_mounts && info "Recovery successful" || error "Recovery incomplete"
            else
                info "No stale mounts detected"
            fi
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
