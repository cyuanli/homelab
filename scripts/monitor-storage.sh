#!/usr/bin/env bash
# Comprehensive Disk Health Monitor for SnapRAID + MergerFS
# Monitors all drives under SnapRAID protection and locks down entire array on ANY failure
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

LOG_FILE="/var/log/disk-monitor.log"
STATE_FILE="/var/lib/disk-monitor/state"
ALERT_FILE="/var/lib/disk-monitor/alert-sent"

# Default drive configuration - can be overridden by config
DATA_PARTITIONS=("sdb1" "sdc1" "sdd1" "sde1")
DATA_MOUNT_POINTS=("/mnt/data4" "/mnt/data2" "/mnt/data3" "/mnt/data1")
PARITY_PARTITIONS=("sdf1")
PARITY_MOUNT_POINTS=("/mnt/parity1")

# Physical drives for SMART checks (remove partition numbers)
DATA_DRIVES=("sdb" "sdc" "sdd" "sde")
PARITY_DRIVES=("sdf")

MERGERFS_MOUNT="/media/data"

ALL_PARTITIONS=("${DATA_PARTITIONS[@]}" "${PARITY_PARTITIONS[@]}")
ALL_DRIVES=("${DATA_DRIVES[@]}" "${PARITY_DRIVES[@]}")
ALL_MOUNT_POINTS=("${DATA_MOUNT_POINTS[@]}" "${PARITY_MOUNT_POINTS[@]}")

# Discord webhook - will be loaded from config
DISCORD_WEBHOOK_URL=""

# Load configuration
load_monitoring_config() {
    load_config

    # Load monitoring-specific config
    local monitoring_config="$HOMELAB_ROOT/config/service-configs/monitoring.conf"
    if [[ -f "$monitoring_config" ]]; then
        log_info "Loading monitoring configuration from $monitoring_config"
        # shellcheck source=/dev/null
        source "$monitoring_config"
    fi

    # Set webhook URL
    DISCORD_WEBHOOK_URL="${DISK_MONITOR_WEBHOOK:-$DISCORD_WEBHOOK_URL}"
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
    mkdir -p "$(dirname "$ALERT_FILE")"
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

    # get mount options
    local opts
    if ! opts=$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null); then
        warn "Could not query mount options for $mount_point"
        opts=""
    fi

    # If mounted read-write, do a safe write test
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

    # Check kernel logs for critical hardware/filesystem errors (last 5 minutes only)
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

# Stop K8s workloads instead of Docker containers
stop_all_k8s_workloads() {
    if ! command -v kubectl >/dev/null 2>&1; then
        info "kubectl missing; skipping k8s workload stop"
        return 0
    fi

    info "Stopping K8s workloads to prevent data loss..."

    # Scale down deployments in media namespace
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

    # Stop workloads (both Docker and K8s)
    stop_all_docker_containers
    stop_all_k8s_workloads
    unmount_mergerfs
    remount_all_drives_readonly

    info "Array lockdown complete - all drives protected"
}

send_discord_alert() {
    local message="$1"
    local severity="${2:-ERROR}"
    local bypass_throttle="${3:-false}"

    if [ "$bypass_throttle" != "true" ] && [ -f "$ALERT_FILE" ]; then
        return 0
    fi

    if [ "$bypass_throttle" != "true" ]; then
        touch "$ALERT_FILE"
    fi

    log "ALERT [$severity]: $message"

    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        local emoji
        case "$severity" in
            "ERROR"|"CRITICAL") emoji=":rotating_light:" ;;
            "WARNING") emoji=":warning:" ;;
            "SCRIPT_ERROR") emoji=":boom:" ;;
            "TEST") emoji=":test_tube:" ;;
            *) emoji=":information_source:" ;;
        esac

        # Escape message for JSON
        local escaped_message
        escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')

        if curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"$emoji **Homelab Storage Alert [$severity]**\\n\\n$escaped_message\"}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1; then
            info "Discord alert sent successfully"
            return 0
        else
            warn "Failed to send Discord alert"
            return 1
        fi
    else
        warn "Discord webhook URL not configured"
        return 1
    fi
}

clear_alert_state() {
    rm -f "$ALERT_FILE" || true
}

export_disk_metrics() {
    local overall_status="$1"  # 1=healthy, 0=failed
    local smart_results="$2"   # Associative array as string
    local mount_results="$3"   # Associative array as string
    local mergerfs_status="$4" # 1=ok, 0=failed

    local timestamp=$(get_timestamp)
    local metrics_content=""

    # Overall disk monitor status
    metrics_content+=$(export_gauge "disk_monitor_status" "$overall_status" 'type="overall"' "Disk monitoring overall status (1=healthy, 0=failed)")
    metrics_content+=$'\n'

    # Individual drive SMART health - output header once, then all data lines
    metrics_content+=$(export_gauge_header "disk_smart_health" "SMART health status per drive (1=pass, 0=fail)")
    metrics_content+=$'\n'
    for i in "${!ALL_DRIVES[@]}"; do
        local drive="${ALL_DRIVES[$i]}"
        local drive_type="data"

        # Determine if this is a parity drive
        for parity_drive in "${PARITY_DRIVES[@]}"; do
            if [ "$drive" = "$parity_drive" ]; then
                drive_type="parity"
                break
            fi
        done

        # Check SMART health (1=pass, 0=fail)
        local smart_value=1
        if ! check_smart_health "$drive" >/dev/null 2>&1; then
            smart_value=0
        fi

        metrics_content+=$(export_gauge_line "disk_smart_health" "$smart_value" "device=\"$drive\",type=\"$drive_type\"")
        metrics_content+=$'\n'
    done

    # Mount point accessibility - output header once, then all data lines
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

    # MergerFS status
    metrics_content+=$(export_gauge "disk_mergerfs_status" "$mergerfs_status" "mount=\"$MERGERFS_MOUNT\"" "MergerFS pool status (1=ok, 0=failed)")
    metrics_content+=$'\n'

    # Last run timestamp
    metrics_content+=$(export_gauge "disk_monitor_last_run_timestamp_seconds" "$timestamp" "" "Last successful monitoring run timestamp")
    metrics_content+=$'\n'

    # Write metrics to file
    write_metric_file "disk_monitor.prom" "$metrics_content"
}

check_all_drives() {
    local failures=()
    local all_healthy=true

    info "Starting comprehensive disk health check..."

    # Data drives
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

    # Parity drives
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

    # MergerFS health check
    local mergerfs_failed=false
    if ! check_mergerfs_health; then
        if [ "$all_healthy" = true ]; then
            mergerfs_failed=true
            warn "MergerFS mount $MERGERFS_MOUNT is not mounted while drives are healthy"
            send_discord_alert "⚠️ **MergerFS UNMOUNTED** on $(hostname)!

MergerFS mount at $MERGERFS_MOUNT is not available, but all storage drives are healthy.

This means your unified storage view is not accessible even though individual drives are working.

**To fix this issue:**
1. Check MergerFS service: \`systemctl status mergerfs\`
2. Manually remount: \`sudo mount $MERGERFS_MOUNT\`
3. Verify access: \`ls -la $MERGERFS_MOUNT\`

Individual drives are still accessible at:
$(printf '• %s\n' "${ALL_MOUNT_POINTS[@]}")" "WARNING" "true"
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

        send_discord_alert "CRITICAL: Drive failure detected on $(hostname)!

All workloads have been stopped and the storage array has been locked down (remounted read-only) to prevent data loss.

Failures detected:
$failure_message

IMMEDIATE ACTION REQUIRED:
1. Investigate the failed drive(s)
2. Replace any failed hardware
3. Verify array integrity with SnapRAID
4. Manually restart services only after confirming data safety

The array will remain locked until manual intervention." "CRITICAL"

        {
            printf 'FAILED\n%s\n%s\n' "$(date)" "$failure_message" > "$STATE_FILE"
        } || true

        # Export failure metrics to Prometheus
        local mergerfs_ok=0
        check_mergerfs_health >/dev/null 2>&1 && mergerfs_ok=1 || mergerfs_ok=0
        export_disk_metrics 0 "" "" "$mergerfs_ok"

        return 1
    else
        info "All drives are healthy"

        # Check if we're recovering from a failure state
        local was_failed=false
        if [ -f "$STATE_FILE" ] && grep -q "FAILED" "$STATE_FILE" 2>/dev/null; then
            was_failed=true
        fi

        # Update state file
        {
            printf 'HEALTHY\n%s\n' "$(date)" > "$STATE_FILE"
        } || true
        clear_alert_state

        # Send recovery notification only if recovering from failure
        if [ "$was_failed" = true ]; then
            send_discord_alert "✅ **RECOVERY COMPLETE** - All drives are now healthy on $(hostname)!

All SnapRAID drives have passed health checks:
• $(printf '/dev/%s ' "${ALL_DRIVES[@]}")

The storage array is functioning normally. Workloads can be safely restarted." "INFO" "true"
        fi

        # Export success metrics to Prometheus
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

test_alert() {
    clear_alert_state
    send_discord_alert "This is a test alert from the disk monitoring system on $(hostname). If you see this message, Discord notifications are working correctly." "TEST"
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
            ;;
        status)
            load_monitoring_config
            show_status
            ;;
        test-alert)
            load_monitoring_config
            test_alert
            ;;
        clear-alert)
            clear_alert_state
            info "Alert state cleared - new alerts will be sent on next failure"
            ;;
        *)
            cat <<EOF
Usage: $0 {check|status|test-alert|clear-alert}

Commands:
  check       - Run comprehensive disk health check (default)
  status      - Show current system status
  test-alert  - Send a test Discord alert
  clear-alert - Clear alert state (allows new alerts)

Configuration:
  Set DISCORD_WEBHOOK_URL in config/homelab.env.local
  Customize drive configuration in config/service-configs/monitoring.conf
EOF
            exit 1
            ;;
    esac
}

main "$@"