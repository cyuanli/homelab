#!/usr/bin/env bash
# Locks down the ENTIRE array on any single drive failure.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

LOG_FILE="/var/log/disk-monitor.log"
STATE_FILE="/var/lib/disk-monitor/state"

DATA_PARTITIONS=("sdb1" "sdc1" "sdd1" "sde1")
DATA_MOUNT_POINTS=("/mnt/data4" "/mnt/data2" "/mnt/data3" "/mnt/data1")
PARITY_PARTITIONS=("sdf1")
PARITY_MOUNT_POINTS=("/mnt/parity1")

DATA_DRIVES=("sdb" "sdc" "sdd" "sde")
PARITY_DRIVES=("sdf")

MERGERFS_MOUNT="/media/data"

# NFS serving layer, not covered by the SMART/mount/mergerfs checks above.
# A mergerfs crash leaves the pool ENOTCONN and nfsd serving stale handles to
# every client, cascading the cluster (2026-08-21). ADVISORY only: never
# triggers lockdown, a stale export is a serving fault, not a drive failure.
# Override in config/service-configs/monitoring.conf.
NFS_SERVER_UNIT="${NFS_SERVER_UNIT:-nfs-server.service}"
NFS_KERNEL_EXPORTS="${NFS_KERNEL_EXPORTS:-/proc/fs/nfs/exports}"
NFS_STAT_TIMEOUT="${NFS_STAT_TIMEOUT:-10}"
NFS_EXPORT_BINDS=("/exports/media" "/exports/configs" "/exports/games")
# fsid=0 (/exports pseudo-root) is implied. /exports/games is served through
# the pseudo-root and has no fsid of its own, so it is only checked as a bind.
NFS_EXPECTED_FSIDS=("1" "2")

ALL_PARTITIONS=("${DATA_PARTITIONS[@]}" "${PARITY_PARTITIONS[@]}")
ALL_DRIVES=("${DATA_DRIVES[@]}" "${PARITY_DRIVES[@]}")
ALL_MOUNT_POINTS=("${DATA_MOUNT_POINTS[@]}" "${PARITY_MOUNT_POINTS[@]}")

load_monitoring_config() {
    load_config

    local monitoring_config="$HOMELAB_ROOT/config/service-configs/monitoring.conf"
    if [[ -f "$monitoring_config" ]]; then
        log_info "Loading monitoring configuration from $monitoring_config"
        # shellcheck source=/dev/null
        source "$monitoring_config"
    fi
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}
error() { log "ERROR: $*"; }
warn()  { log "WARNING: $*"; }
info()  { log "INFO: $*"; }

check_dependencies() {
    local missing_deps=()
    command -v smartctl >/dev/null 2>&1 || missing_deps+=("smartmontools")
    command -v findmnt >/dev/null 2>&1 || missing_deps+=("util-linux")
    command -v mountpoint >/dev/null 2>&1 || missing_deps+=("mountpoint")

    if ! command -v docker >/dev/null 2>&1; then
        warn "docker not found - docker stop operations will be skipped"
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
        error "Install with: sudo apt install ${missing_deps[*]}"
        return 1
    fi
    return 0
}

ensure_directories() {
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    touch "$STATE_FILE" || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
    return 0
}

check_smart_health() {
    local device="$1"
    local health_status

    health_status=$(smartctl -H "/dev/$device" 2>/dev/null | grep -i "smart.*health" | awk '{print $NF}')

    if [[ -z "$health_status" ]]; then
        error "Failed to get SMART health for /dev/$device - no health status found"
        return 1
    fi

    info "SMART health for /dev/$device: $health_status"

    if [[ "$health_status" != "PASSED" && "$health_status" != "OK" ]]; then
        error "SMART health check FAILED for /dev/$device: $health_status"
        return 1
    fi

    return 0
}

check_mount_point() {
    local mount_point="$1"
    local partition="$2"

    if ! mountpoint -q "$mount_point"; then
        error "Mount point $mount_point is not mounted"
        return 1
    fi

    local opts
    if ! opts=$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null); then
        warn "Could not query mount options for $mount_point"
        opts=""
    fi

    if echo "$opts" | grep -qw "ro"; then
        info "$mount_point mounted read-only"
    else
        local tf
        if ! tf=$(mktemp -p "$mount_point" .disk-health-test.XXXX 2>/dev/null); then
            error "Cannot create test file on $mount_point (write failed)"
            return 1
        fi
        rm -f "$tf" || true
    fi

    if dmesg -T --since "5 minutes ago" 2>/dev/null | grep -E "(ext4_mb_generate_buddy.*corruption|EXT4-fs error.*Corrupt|XFS.*Metadata corruption|xfs_inode_buf_verify.*bad magic|COMRESET failed \(errno=-16\)|link is slow to respond.*ready=0|SStatus.*SError.*UnrecovData|blk_update_request: I/O error.*sector [0-9]+|status: \{ DRDY ERR \}.*error: \{ UNC \}|ata[0-9]+\.00: exception Emask.*frozen)" | grep -i "$partition" >/dev/null; then
        error "Critical hardware/filesystem errors detected for $partition / $mount_point"
        return 1
    fi

    return 0
}

check_mergerfs_health() {
    if ! mountpoint -q "$MERGERFS_MOUNT"; then
        warn "MergerFS mount $MERGERFS_MOUNT is not mounted (may be expected during failure recovery)"
        return 1
    fi

    local tf
    if ! tf=$(mktemp -p "$MERGERFS_MOUNT" .disk-health-test.XXXX 2>/dev/null); then
        error "Cannot write to MergerFS mount $MERGERFS_MOUNT"
        return 1
    fi
    rm -f "$tf" || true
    return 0
}

stop_all_docker_containers() {
    if ! command -v docker >/dev/null 2>&1; then
        info "docker missing; skipping container stop"
        return 0
    fi

    info "Stopping ALL Docker containers to prevent data loss..."
    local running_containers
    if running_containers=$(docker ps -q 2>/dev/null); then
        if [ -n "$running_containers" ]; then
            info "Stopping containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
            echo "$running_containers" | xargs -r docker stop
            info "All Docker containers stopped"
        else
            info "No running Docker containers found"
        fi
    else
        warn "Failed to query Docker containers"
    fi
}

stop_all_k8s_workloads() {
    if ! command -v kubectl >/dev/null 2>&1; then
        info "kubectl missing; skipping k8s workload stop"
        return 0
    fi

    info "Stopping K8s workloads to prevent data loss..."

    local namespaces=("media" "cloud")
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            info "Scaling down deployments in namespace: $ns"
            kubectl scale deployment --all --replicas=0 -n "$ns" || true
        fi
    done
}

unmount_mergerfs() {
    if mountpoint -q "$MERGERFS_MOUNT"; then
        info "Unmounting MergerFS pool: $MERGERFS_MOUNT"
        if umount "$MERGERFS_MOUNT"; then
            info "MergerFS pool unmounted successfully"
            return 0
        else
            error "Failed to unmount MergerFS pool"
            return 1
        fi
    else
        info "MergerFS pool already unmounted"
    fi
    return 0
}

remount_all_drives_readonly() {
    info "Remounting ALL SnapRAID drives as read-only..."
    for mount_point in "${ALL_MOUNT_POINTS[@]}"; do
        if mountpoint -q "$mount_point"; then
            local opts
            opts=$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null || true)
            if echo "$opts" | grep -qw "ro"; then
                info "$mount_point already mounted read-only"
            else
                info "Remounting $mount_point as read-only"
                if mount -o remount,ro "$mount_point"; then
                    info "Successfully remounted $mount_point as read-only"
                else
                    error "Failed to remount $mount_point as read-only"
                fi
            fi
        else
            warn "$mount_point is not mounted"
        fi
    done
}

lockdown_array() {
    info "INITIATING ARRAY LOCKDOWN - Drive failure detected"

    stop_all_docker_containers
    stop_all_k8s_workloads
    unmount_mergerfs
    remount_all_drives_readonly

    info "Array lockdown complete - all drives protected"
}


export_disk_metrics() {
    local overall_status="$1"
    local smart_results="$2"
    local mount_results="$3"
    local mergerfs_status="$4"

    local timestamp=$(get_timestamp)
    local metrics_content=""

    metrics_content+=$(export_gauge "disk_monitor_status" "$overall_status" 'type="overall"' "Disk monitoring overall status (1=healthy, 0=failed)")
    metrics_content+=$'\n'

    metrics_content+=$(export_gauge_header "disk_smart_health" "SMART health status per drive (1=pass, 0=fail)")
    metrics_content+=$'\n'
    for i in "${!ALL_DRIVES[@]}"; do
        local drive="${ALL_DRIVES[$i]}"
        local drive_type="data"

        for parity_drive in "${PARITY_DRIVES[@]}"; do
            if [ "$drive" = "$parity_drive" ]; then
                drive_type="parity"
                break
            fi
        done

        local smart_value=1
        if ! check_smart_health "$drive" >/dev/null 2>&1; then
            smart_value=0
        fi

        metrics_content+=$(export_gauge_line "disk_smart_health" "$smart_value" "device=\"$drive\",type=\"$drive_type\"")
        metrics_content+=$'\n'
    done

    metrics_content+=$(export_gauge_header "disk_mount_accessible" "Mount point accessibility (1=ok, 0=failed)")
    metrics_content+=$'\n'
    for i in "${!ALL_MOUNT_POINTS[@]}"; do
        local mount_point="${ALL_MOUNT_POINTS[$i]}"
        local mount_value=1

        if ! mountpoint -q "$mount_point"; then
            mount_value=0
        fi

        metrics_content+=$(export_gauge_line "disk_mount_accessible" "$mount_value" "mount=\"$mount_point\"")
        metrics_content+=$'\n'
    done

    metrics_content+=$(export_gauge "disk_mergerfs_status" "$mergerfs_status" "mount=\"$MERGERFS_MOUNT\"" "MergerFS pool status (1=ok, 0=failed)")
    metrics_content+=$'\n'

    metrics_content+=$(export_gauge "disk_monitor_last_run_timestamp_seconds" "$timestamp" "" "Last successful monitoring run timestamp")
    metrics_content+=$'\n'

    write_metric_file "disk_monitor.prom" "$metrics_content"
}

export_nfs_export_metrics() {
    local overall_status="$1"

    local metrics_content=""

    metrics_content+=$(export_gauge "nfs_export_status" "$overall_status" 'type="overall"' "NFS export layer health (1=healthy, 0=degraded)")
    metrics_content+=$'\n'

    local server_active=0
    if systemctl is-active --quiet "$NFS_SERVER_UNIT"; then
        server_active=1
    fi
    metrics_content+=$(export_gauge "nfs_server_active" "$server_active" "unit=\"$NFS_SERVER_UNIT\"" "NFS server unit active (1=active, 0=inactive)")
    metrics_content+=$'\n'

    metrics_content+=$(export_gauge_header "nfs_export_bind_accessible" "NFS export bind accessible (1=ok, 0=stale/missing)")
    metrics_content+=$'\n'
    for bind in "${NFS_EXPORT_BINDS[@]}"; do
        local bind_value=0
        if mountpoint -q "$bind" && timeout "$NFS_STAT_TIMEOUT" stat "$bind" >/dev/null 2>&1; then
            bind_value=1
        fi
        metrics_content+=$(export_gauge_line "nfs_export_bind_accessible" "$bind_value" "mount=\"$bind\"")
        metrics_content+=$'\n'
    done

    metrics_content+=$(export_gauge_header "nfs_export_fsid_present" "Expected fsid present in kernel export table (1=present, 0=missing)")
    metrics_content+=$'\n'
    for fsid in "${NFS_EXPECTED_FSIDS[@]}"; do
        local fsid_value=0
        if [[ -r "$NFS_KERNEL_EXPORTS" ]] && grep -qE "fsid=${fsid}[,)]" "$NFS_KERNEL_EXPORTS" 2>/dev/null; then
            fsid_value=1
        fi
        metrics_content+=$(export_gauge_line "nfs_export_fsid_present" "$fsid_value" "fsid=\"$fsid\"")
        metrics_content+=$'\n'
    done

    metrics_content+=$(export_gauge "nfs_export_last_run_timestamp_seconds" "$(get_timestamp)" "" "Last NFS export health check timestamp")
    metrics_content+=$'\n'

    write_metric_file "nfs_export.prom" "$metrics_content"
}

check_nfs_export_layer() {
    info "Checking server-side NFS export layer..."
    local healthy=true

    if ! systemctl is-active --quiet "$NFS_SERVER_UNIT"; then
        error "NFS server ($NFS_SERVER_UNIT) is not active - exports are down"
        healthy=false
    fi

    # Timed stat: an ENOTCONN pool or stale bind would otherwise hang forever.
    for bind in "${NFS_EXPORT_BINDS[@]}"; do
        if ! mountpoint -q "$bind"; then
            error "NFS export bind $bind is not mounted - clients will get stale handles"
            healthy=false
        elif ! timeout "$NFS_STAT_TIMEOUT" stat "$bind" >/dev/null 2>&1; then
            error "NFS export bind $bind is not accessible (stale/ENOTCONN pool?)"
            healthy=false
        fi
    done

    # A bind can look fine locally while nfsd has dropped its export, leaving
    # clients unable to mount. Fix is 'exportfs -ra'.
    if [[ -r "$NFS_KERNEL_EXPORTS" ]]; then
        for fsid in "${NFS_EXPECTED_FSIDS[@]}"; do
            if ! grep -qE "fsid=${fsid}[,)]" "$NFS_KERNEL_EXPORTS" 2>/dev/null; then
                error "NFS export table is missing fsid=$fsid (nfsd not exporting; needs 'exportfs -ra')"
                healthy=false
            fi
        done
    else
        warn "Cannot read $NFS_KERNEL_EXPORTS - skipping export-table check"
    fi

    if [[ "$healthy" == true ]]; then
        export_nfs_export_metrics 1
        info "NFS export layer healthy (server active, binds accessible, fsids exported)"
        return 0
    fi

    export_nfs_export_metrics 0
    error "NFS export layer DEGRADED (see errors above). Workloads NOT locked down - this is an NFS serving issue, not a drive failure. Recover the pool/binds and re-run 'sudo exportfs -ra'."
    return 1
}

check_all_drives() {
    local failures=()
    local all_healthy=true

    info "Starting comprehensive disk health check..."

    for i in "${!DATA_DRIVES[@]}"; do
        local drive="${DATA_DRIVES[$i]}"
        local partition="${DATA_PARTITIONS[$i]}"
        local mount_point="${DATA_MOUNT_POINTS[$i]}"

        info "Checking data drive /dev/$drive (partition $partition) mounted at $mount_point"

        if ! check_smart_health "$drive"; then
            failures+=("Data drive /dev/$drive: SMART health failure")
            all_healthy=false
        fi

        if ! check_mount_point "$mount_point" "$partition"; then
            failures+=("Data drive /dev/$drive: Mount/access failure at $mount_point")
            all_healthy=false
        fi
    done

    for i in "${!PARITY_DRIVES[@]}"; do
        local drive="${PARITY_DRIVES[$i]}"
        local partition="${PARITY_PARTITIONS[$i]}"
        local mount_point="${PARITY_MOUNT_POINTS[$i]}"

        info "Checking parity drive /dev/$drive (partition $partition) mounted at $mount_point"

        if ! check_smart_health "$drive"; then
            failures+=("Parity drive /dev/$drive: SMART health failure")
            all_healthy=false
        fi

        if ! check_mount_point "$mount_point" "$partition"; then
            failures+=("Parity drive /dev/$drive: Mount/access failure at $mount_point")
            all_healthy=false
        fi
    done

    local mergerfs_failed=false
    if ! check_mergerfs_health; then
        if [ "$all_healthy" = true ]; then
            mergerfs_failed=true
            warn "MergerFS mount $MERGERFS_MOUNT is not mounted while drives are healthy"
        else
            info "MergerFS health check failed (expected during drive failure recovery)"
        fi
    fi

    if [ "$all_healthy" = false ]; then
        local failure_message
        failure_message=$(printf '%s\n' "${failures[@]}")

        error "DRIVE FAILURE DETECTED!"
        error "$failure_message"

        lockdown_array

        {
            printf 'FAILED\n%s\n%s\n' "$(date)" "$failure_message" > "$STATE_FILE"
        } || true

        local mergerfs_ok=0
        check_mergerfs_health >/dev/null 2>&1 && mergerfs_ok=1 || mergerfs_ok=0
        export_disk_metrics 0 "" "" "$mergerfs_ok"

        return 1
    else
        info "All drives are healthy"

        local was_failed=false
        if [ -f "$STATE_FILE" ] && grep -q "FAILED" "$STATE_FILE" 2>/dev/null; then
            was_failed=true
        fi

        {
            printf 'HEALTHY\n%s\n' "$(date)" > "$STATE_FILE"
        } || true

        if [ "$was_failed" = true ]; then
            info "RECOVERY COMPLETE - All drives are now healthy on $(hostname)"
            info "All SnapRAID drives have passed health checks: $(printf '/dev/%s ' "${ALL_DRIVES[@]}")"
        fi

        local mergerfs_ok=0
        check_mergerfs_health >/dev/null 2>&1 && mergerfs_ok=1 || mergerfs_ok=0
        export_disk_metrics 1 "" "" "$mergerfs_ok"

        return 0
    fi
}

show_status() {
    echo "=== Disk Monitor Status ==="
    if [ -f "$STATE_FILE" ]; then
        echo "Current State: $(head -1 "$STATE_FILE")"
        if grep -q "FAILED" "$STATE_FILE" 2>/dev/null; then
            echo ""
            echo "=== Failure Details ==="
            tail -n +2 "$STATE_FILE"
        fi
    else
        echo "Current State: UNKNOWN (never run)"
    fi

    echo ""
    echo "=== Mount Status ==="
    for mount_point in "${ALL_MOUNT_POINTS[@]}" "$MERGERFS_MOUNT"; do
        if mountpoint -q "$mount_point"; then
            local opts
            opts=$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null || true)
            if echo "$opts" | grep -qw "ro"; then
                echo "$mount_point: MOUNTED (READ-ONLY)"
            else
                echo "$mount_point: MOUNTED (READ-WRITE)"
            fi
        else
            echo "$mount_point: NOT MOUNTED"
        fi
    done

    echo ""
    echo "=== NFS Export Layer ==="
    if systemctl is-active --quiet "$NFS_SERVER_UNIT"; then
        echo "$NFS_SERVER_UNIT: active"
    else
        echo "$NFS_SERVER_UNIT: NOT ACTIVE"
    fi
    for bind in "${NFS_EXPORT_BINDS[@]}"; do
        if mountpoint -q "$bind" && timeout "$NFS_STAT_TIMEOUT" stat "$bind" >/dev/null 2>&1; then
            echo "$bind: OK"
        else
            echo "$bind: STALE/MISSING"
        fi
    done
    if [[ -r "$NFS_KERNEL_EXPORTS" ]]; then
        for fsid in "${NFS_EXPECTED_FSIDS[@]}"; do
            if grep -qE "fsid=${fsid}[,)]" "$NFS_KERNEL_EXPORTS" 2>/dev/null; then
                echo "export fsid=$fsid: present"
            else
                echo "export fsid=$fsid: MISSING (run 'sudo exportfs -ra')"
            fi
        done
    fi

    echo ""
    echo "=== Workload Status ==="
    if command -v kubectl >/dev/null 2>&1; then
        echo "K8s workloads:"
        kubectl get pods -n media 2>/dev/null | grep -v "0/1.*Completed" || echo "No media pods running"
    fi

    if command -v docker >/dev/null 2>&1; then
        local running_containers
        running_containers=$(docker ps --format '{{.Names}}' | sed '/^\s*$/d' || true)
        if [ -n "$running_containers" ]; then
            echo "Running containers:"
            echo "$running_containers"
        else
            echo "No running containers"
        fi
    fi

    echo ""
    echo "=== Drive Health Summary ==="
    for drive in "${ALL_DRIVES[@]}"; do
        if check_smart_health "$drive" >/dev/null 2>&1; then
            echo "/dev/$drive: SMART OK"
        else
            echo "/dev/$drive: SMART FAILED"
        fi
    done
}


main() {
    case "${1:-check}" in
        check)
            load_monitoring_config

            if ! check_dependencies; then
                log_error "Missing dependencies"
                exit 1
            fi

            if ! ensure_directories; then
                log_error "Failed to create directories"
                exit 1
            fi

            if ! check_all_drives; then
                exit 1
            fi

            # Runs only once drives/pool are healthy, so a real drive failure
            # short-circuits above.
            if ! check_nfs_export_layer; then
                exit 1
            fi
            ;;
        status)
            load_monitoring_config
            show_status
            ;;
        *)
            cat <<EOF
Usage: $0 {check|status}

Commands:
  check       - Run comprehensive disk health check (default)
  status      - Show current system status

Configuration:
  Customize drive configuration in config/service-configs/monitoring.conf
  Alerts are handled by Prometheus/Alertmanager
EOF
            exit 1
            ;;
    esac
}

main "$@"