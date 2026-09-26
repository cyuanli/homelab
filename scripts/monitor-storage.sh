#!/usr/bin/env bash
# Locks down the array on any drive failure. Drives are read from snapraid.conf
# and resolved to devices at runtime; /dev/sdX letters change between boots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"
# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

SNAPRAID_CONF="${SNAPRAID_CONF:-/etc/snapraid.conf}"
MERGERFS_MOUNT="${MERGERFS_MOUNT:-/media/data}"
STATE_DIR="/var/lib/disk-monitor"
STATE_FILE="$STATE_DIR/state"
RESTORE_FILE="$STATE_DIR/restore.sh"
LOG_FILE="/var/log/disk-monitor.log"
DRY_RUN="${DRY_RUN:-0}"
LOCKDOWN_TIMEOUT="${LOCKDOWN_TIMEOUT:-180}"
LOCKDOWN_TIMERS=("snapraid-runner.timer" "borgmatic.timer")
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# PVs whose NFS path is under one of these (relative to the /exports pseudo-root) live on the pool.
POOL_NFS_PATHS=("/media" "/games")

# ADVISORY only: a stale export is a serving fault, never a lockdown trigger.
# A mergerfs crash leaves the pool ENOTCONN and nfsd serving stale handles (2026-08-21).
NFS_SERVER_UNIT="${NFS_SERVER_UNIT:-nfs-server.service}"
NFS_KERNEL_EXPORTS="${NFS_KERNEL_EXPORTS:-/proc/fs/nfs/exports}"
NFS_STAT_TIMEOUT="${NFS_STAT_TIMEOUT:-10}"
NFS_EXPORT_BINDS=("/exports/media" "/exports/configs" "/exports/games")
# fsid=0 is implied; /exports/games has no fsid of its own.
NFS_EXPECTED_FSIDS=("1" "2")

MOUNTS=() ROLES=() DISKS=() SERIALS=()

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}
error() { log "ERROR: $*"; }
warn()  { log "WARNING: $*"; }
info()  { log "INFO: $*"; }

run() {
    if [[ $DRY_RUN == 1 ]]; then
        info "DRY RUN: $*"
    else
        "$@"
    fi
}

record_restore() {
    if [[ $DRY_RUN == 1 ]]; then
        info "DRY RUN restore: $*"
    elif ! grep -qxF -- "$*" "$RESTORE_FILE" 2>/dev/null; then
        # prepend so the file undoes in reverse order
        { head -n 3 "$RESTORE_FILE"; printf '%s\n' "$*"; tail -n +4 "$RESTORE_FILE"; } > "$RESTORE_FILE.tmp"
        mv "$RESTORE_FILE.tmp" "$RESTORE_FILE"
        chmod 700 "$RESTORE_FILE"
    fi
}

is_ro() {
    local opts
    opts=$(findmnt -no OPTIONS --mountpoint "$1" 2>/dev/null) || return 1
    [[ ",$opts," == *,ro,* ]]
}

discover_array() {
    local key a b mp part disk
    [[ -r $SNAPRAID_CONF ]] || { error "Cannot read $SNAPRAID_CONF"; exit 1; }
    while read -r key a b _; do
        case "$key" in
            data) mp="${b%/}"; ROLES+=("data") ;;
            parity|[2-6]-parity|z-parity) mp="$(dirname "${a%%,*}")"; ROLES+=("parity") ;;
            *) continue ;;
        esac
        MOUNTS+=("$mp")
        part=$(findmnt -no SOURCE --mountpoint "$mp" 2>/dev/null || findmnt -s -e -no SOURCE --mountpoint "$mp" 2>/dev/null || true)
        disk=""
        if [[ -b $part ]]; then
            disk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
            disk="${disk:-$(basename "$part")}"
        fi
        DISKS+=("${disk:-unknown}")
        SERIALS+=("$([[ -n $disk ]] && lsblk -dno SERIAL "/dev/$disk" 2>/dev/null || echo unknown)")
    done < <(sed 's/#.*//' "$SNAPRAID_CONF")
    (( ${#MOUNTS[@]} )) || { error "No data/parity disks found in $SNAPRAID_CONF"; exit 1; }
}

check_smart_health() {
    local disk="$1" status
    [[ $disk != unknown ]] || { error "No block device found for this mount"; return 1; }
    status=$(smartctl -H "/dev/$disk" 2>/dev/null | awk 'tolower($0) ~ /smart.*health/ {print $NF}')
    if [[ $status != PASSED && $status != OK ]]; then
        error "SMART health for /dev/$disk: ${status:-no result}"
        return 1
    fi
}

kernel_errors() {
    local disk="$1" ata pattern log_text
    [[ $disk != unknown ]] || return 1
    ata=$(readlink -f "/sys/block/$disk" | grep -oE 'ata[0-9]+' | head -1 || true)
    pattern="error, dev $disk,|Buffer I/O error on dev $disk[0-9]*,|EXT4-fs error \(device $disk[0-9]*\)|XFS \($disk[0-9]*\): .*[Cc]orruption"
    [[ -n $ata ]] && pattern+="|$ata\.[0-9]{2}: error: \{[^}]*UNC"
    log_text=$(dmesg --since "5 minutes ago" 2>/dev/null || true)
    grep -E "$pattern" <<< "$log_text"
}

check_mount_point() {
    local mp="$1" disk="$2" tf errs
    if ! mountpoint -q "$mp"; then
        error "$mp is not mounted"
        return 1
    fi
    if is_ro "$mp"; then
        info "$mp is mounted read-only"
    elif tf=$(timeout "$NFS_STAT_TIMEOUT" mktemp -p "$mp" .disk-health-test.XXXX 2>/dev/null); then
        rm -f "$tf"
    else
        error "Cannot write a test file on $mp"
        return 1
    fi
    if errs=$(kernel_errors "$disk"); then
        error "Kernel reported errors for /dev/$disk ($mp):"$'\n'"$errs"
        return 1
    fi
}

check_mergerfs_health() {
    local tf
    mountpoint -q "$MERGERFS_MOUNT" || return 1
    is_ro "$MERGERFS_MOUNT" && return 0
    tf=$(timeout "$NFS_STAT_TIMEOUT" mktemp -p "$MERGERFS_MOUNT" .disk-health-test.XXXX 2>/dev/null) || return 1
    rm -f "$tf"
}

# "ns claim" for every bound PV on the pool
pool_claims() {
    kubectl get pv -o json | jq -r --args '
        .items[] | select(.spec.nfs and .spec.claimRef)
        | .spec.nfs.path as $p
        | select(any($ARGS.positional[] as $pre | $p == $pre or ($p | startswith($pre + "/")); .))
        | "\(.spec.claimRef.namespace) \(.spec.claimRef.name)"' "${POOL_NFS_PATHS[@]}"
}

# $1 = kubectl resource list; prints matching items as JSON lines
using_pool() {
    local claims
    claims=$(pool_claims | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
    kubectl get "$1" -A -o json | jq -c --argjson c "$claims" '
        .items[] | .metadata.namespace as $ns
        | (if .kind == "CronJob" then .spec.jobTemplate.spec.template
           elif .kind == "Pod" then . else .spec.template end) as $t
        | select(any($t.spec.volumes[]?; .persistentVolumeClaim.claimName as $n
                 | $n != null and ($c | index("\($ns) \($n)")) != null))'
}

stop_pool_workloads() {
    local items kind ns name val
    if ! items=$(using_pool deployment,statefulset,cronjob | jq -r '"\(.kind) \(.metadata.namespace) \(.metadata.name) \(if .kind == "CronJob" then (.spec.suspend // false) else .spec.replicas end)"'); then
        error "Cannot query Kubernetes (KUBECONFIG=$KUBECONFIG); pool workloads NOT stopped"
        return 1
    fi
    while read -r kind ns name val; do
        [[ -n $kind ]] || continue
        if [[ $kind == CronJob ]]; then
            [[ $val == true ]] && continue
            info "Suspending cronjob $ns/$name"
            run kubectl -n "$ns" patch cronjob "$name" -p '{"spec":{"suspend":true}}'
            record_restore "kubectl -n $ns patch cronjob $name -p '{\"spec\":{\"suspend\":false}}'"
        else
            [[ $val == 0 ]] && continue
            info "Scaling ${kind,,} $ns/$name from $val to 0"
            run kubectl -n "$ns" scale "${kind,,}" "$name" --replicas=0
            record_restore "kubectl -n $ns scale ${kind,,} $name --replicas=$val"
        fi
    done <<< "$items"

    using_pool job | jq -r 'select((.status.active // 0) > 0) | "\(.metadata.namespace) \(.metadata.name)"' |
        while read -r ns name; do
            info "Deleting running job $ns/$name"
            run kubectl -n "$ns" delete job "$name" --wait=false
        done
}

wait_pool_pods() {
    local remaining waited=0
    [[ $DRY_RUN == 1 ]] && return 0
    while :; do
        remaining=$(using_pool pod | jq -r 'select(.status.phase == "Running" or .status.phase == "Pending") | "\(.metadata.namespace)/\(.metadata.name)"') ||
            { error "Cannot list pods using the pool"; return 1; }
        [[ -z $remaining ]] && break
        if (( waited >= LOCKDOWN_TIMEOUT )); then
            error "Pods still using the pool after ${LOCKDOWN_TIMEOUT}s: $(tr '\n' ' ' <<< "$remaining")"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    info "No pods are using the pool"
}

stop_timers() {
    local t
    for t in "${LOCKDOWN_TIMERS[@]}"; do
        systemctl is-enabled --quiet "$t" 2>/dev/null || continue
        info "Disabling $t"
        run systemctl disable --now "$t"
        record_restore "systemctl enable --now $t"
    done
}

# Unlike remount, this cannot fail with EBUSY, so pool writes stop even if a disk stays busy.
freeze_pool() {
    local ctl="$MERGERFS_MOUNT/.mergerfs" branches frozen
    if ! branches=$(getfattr --only-values -n user.mergerfs.branches "$ctl" 2>/dev/null); then
        error "Cannot read mergerfs branches from $ctl (attr package missing, or pool down)"
        return 1
    fi
    frozen=$(sed -E 's/=(RW|NC)/=RO/g' <<< "$branches")
    [[ $frozen == "$branches" ]] && return 0
    info "Setting all mergerfs branches read-only"
    if ! run setfattr -n user.mergerfs.branches -v "$frozen" "$ctl"; then
        error "Could not set mergerfs branches read-only"
        return 1
    fi
    record_restore "setfattr -n user.mergerfs.branches -v '$branches' $ctl"
}

# Pool stays mounted: unmounting it exposes the empty mountpoint on the root disk.
remount_array_readonly() {
    local mp attempt ok=0
    for mp in "${MOUNTS[@]}"; do
        mountpoint -q "$mp" || { warn "$mp is not mounted"; continue; }
        is_ro "$mp" && continue
        for attempt in 1 2 3 4 5 6; do
            if run timeout 60 mount -o remount,ro "$mp"; then
                info "Remounted $mp read-only"
                record_restore "mount -o remount,rw $mp"
                continue 2
            fi
            sleep 10
        done
        error "Could not remount $mp read-only. Processes holding it: $(fuser -vm "$mp" 2>&1 | tail -n +2 | awk '{print $NF}' | sort -u | tr '\n' ' ')"
        ok=1
    done
    return "$ok"
}

lockdown_array() {
    local rc=0
    info "INITIATING ARRAY LOCKDOWN"
    if [[ $DRY_RUN != 1 && ! -e $RESTORE_FILE ]]; then
        printf '#!/bin/sh\n# Undo for the lockdown of %s. Run only after the array is verified healthy.\nset -x\n' "$(date)" > "$RESTORE_FILE"
        chmod 700 "$RESTORE_FILE"
    fi
    stop_timers || rc=1
    stop_pool_workloads || rc=1
    freeze_pool || rc=1
    wait_pool_pods || rc=1
    remount_array_readonly || rc=1
    if (( rc )); then
        error "LOCKDOWN INCOMPLETE - see errors above"
    elif [[ $DRY_RUN == 1 ]]; then
        info "Dry run complete. Nothing was changed"
    else
        info "Lockdown complete. Undo commands: $RESTORE_FILE"
    fi
    return "$rc"
}

export_disk_metrics() {
    local overall="$1" i v content
    content=$(export_gauge "disk_monitor_status" "$overall" 'type="overall"' "Disk monitoring overall status (1=healthy, 0=failed)")$'\n'
    content+=$(export_gauge_header "disk_smart_health" "SMART health status per drive (1=pass, 0=fail)")$'\n'
    for i in "${!MOUNTS[@]}"; do
        v=1; check_smart_health "${DISKS[$i]}" >/dev/null 2>&1 || v=0
        content+=$(export_gauge_line "disk_smart_health" "$v" "device=\"${DISKS[$i]}\",serial=\"${SERIALS[$i]}\",mount=\"${MOUNTS[$i]}\",type=\"${ROLES[$i]}\"")$'\n'
    done
    content+=$(export_gauge_header "disk_mount_accessible" "Mount point accessibility (1=ok, 0=failed)")$'\n'
    for i in "${!MOUNTS[@]}"; do
        v=1; mountpoint -q "${MOUNTS[$i]}" || v=0
        content+=$(export_gauge_line "disk_mount_accessible" "$v" "mount=\"${MOUNTS[$i]}\"")$'\n'
    done
    v=1; check_mergerfs_health || v=0
    content+=$(export_gauge "disk_mergerfs_status" "$v" "mount=\"$MERGERFS_MOUNT\"" "MergerFS pool status (1=ok, 0=failed)")$'\n'
    content+=$(export_gauge "disk_monitor_last_run_timestamp_seconds" "$(get_timestamp)" "" "Last successful monitoring run timestamp")
    write_metric_file "disk_monitor.prom" "$content"
}

bind_ok() { mountpoint -q "$1" && timeout "$NFS_STAT_TIMEOUT" stat "$1" >/dev/null 2>&1; }
fsid_ok() { [[ -r $NFS_KERNEL_EXPORTS ]] && grep -qE "fsid=$1[,)]" "$NFS_KERNEL_EXPORTS"; }

check_nfs_export_layer() {
    local healthy=1 server=1 bind fsid v content
    if ! systemctl is-active --quiet "$NFS_SERVER_UNIT"; then
        error "$NFS_SERVER_UNIT is not active - exports are down"
        healthy=0 server=0
    fi
    content=$(export_gauge_header "nfs_export_bind_accessible" "NFS export bind accessible (1=ok, 0=stale/missing)")$'\n'
    for bind in "${NFS_EXPORT_BINDS[@]}"; do
        v=1
        if ! bind_ok "$bind"; then
            error "NFS export bind $bind is not mounted or not accessible (stale/ENOTCONN pool?)"
            healthy=0 v=0
        fi
        content+=$(export_gauge_line "nfs_export_bind_accessible" "$v" "mount=\"$bind\"")$'\n'
    done
    content+=$(export_gauge_header "nfs_export_fsid_present" "Expected fsid present in kernel export table (1=present, 0=missing)")$'\n'
    for fsid in "${NFS_EXPECTED_FSIDS[@]}"; do
        v=1
        if [[ ! -r $NFS_KERNEL_EXPORTS ]]; then
            warn "Cannot read $NFS_KERNEL_EXPORTS - skipping export-table check"
        elif ! fsid_ok "$fsid"; then
            error "NFS export table is missing fsid=$fsid (needs 'exportfs -ra')"
            healthy=0 v=0
        fi
        content+=$(export_gauge_line "nfs_export_fsid_present" "$v" "fsid=\"$fsid\"")$'\n'
    done
    content+=$(export_gauge "nfs_server_active" "$server" "unit=\"$NFS_SERVER_UNIT\"" "NFS server unit active (1=active, 0=inactive)")$'\n'
    content+=$(export_gauge "nfs_export_status" "$healthy" 'type="overall"' "NFS export layer health (1=healthy, 0=degraded)")$'\n'
    content+=$(export_gauge "nfs_export_last_run_timestamp_seconds" "$(get_timestamp)" "" "Last NFS export health check timestamp")
    write_metric_file "nfs_export.prom" "$content"

    if (( healthy )); then
        info "NFS export layer healthy"
        return 0
    fi
    error "NFS export layer DEGRADED. Not a drive failure, so no lockdown. Recover the pool/binds, then 'sudo exportfs -ra'."
    return 1
}

check_all_drives() {
    local i f failures=()
    for i in "${!MOUNTS[@]}"; do
        check_smart_health "${DISKS[$i]}" || failures+=("${MOUNTS[$i]} (${SERIALS[$i]}): SMART health failure")
        check_mount_point "${MOUNTS[$i]}" "${DISKS[$i]}" || failures+=("${MOUNTS[$i]} (${SERIALS[$i]}): mount/access failure")
    done

    if (( ${#failures[@]} == 0 )); then
        info "All drives are healthy"
        check_mergerfs_health || warn "MergerFS pool $MERGERFS_MOUNT is not mounted or not writable while drives are healthy"
        printf 'HEALTHY\n%s\n' "$(date)" > "$STATE_FILE"
        if [[ -e $RESTORE_FILE ]]; then
            warn "Drives pass but the array is still locked down. Once verified, run 'sh $RESTORE_FILE' and delete it"
            export_disk_metrics 0
        else
            export_disk_metrics 1
        fi
        return 0
    fi

    error "DRIVE FAILURE DETECTED:"
    for f in "${failures[@]}"; do error "  $f"; done
    mark_failed "$(printf '%s\n' "${failures[@]}")"
    export_disk_metrics 0
    lockdown_array || true
    return 1
}

show_status() {
    local i mp state bind fsid
    echo "=== State ==="
    if [[ -r $STATE_FILE ]]; then cat "$STATE_FILE"; else echo "UNKNOWN (never run, or not readable)"; fi
    [[ -e $RESTORE_FILE ]] && echo "Lockdown undo file present: $RESTORE_FILE"

    echo; echo "=== Drives (from $SNAPRAID_CONF) ==="
    for i in "${!MOUNTS[@]}"; do
        mp="${MOUNTS[$i]}"
        if ! mountpoint -q "$mp"; then state="NOT MOUNTED"
        elif is_ro "$mp"; then state="READ-ONLY"
        else state="read-write"; fi
        printf '%-14s %-7s /dev/%-5s %-20s %-12s' "$mp" "${ROLES[$i]}" "${DISKS[$i]}" "${SERIALS[$i]}" "$state"
        if (( EUID != 0 )); then echo "SMART: needs root"
        elif check_smart_health "${DISKS[$i]}" >/dev/null 2>&1; then echo "SMART: OK"
        else echo "SMART: FAILED"; fi
    done
    if check_mergerfs_health; then echo "$MERGERFS_MOUNT: OK"; else echo "$MERGERFS_MOUNT: NOT MOUNTED/WRITABLE"; fi

    echo; echo "=== NFS export layer ==="
    systemctl is-active --quiet "$NFS_SERVER_UNIT" && echo "$NFS_SERVER_UNIT: active" || echo "$NFS_SERVER_UNIT: NOT ACTIVE"
    for bind in "${NFS_EXPORT_BINDS[@]}"; do
        bind_ok "$bind" && echo "$bind: OK" || echo "$bind: STALE/MISSING"
    done
    for fsid in "${NFS_EXPECTED_FSIDS[@]}"; do
        fsid_ok "$fsid" && echo "export fsid=$fsid: present" || echo "export fsid=$fsid: MISSING or unreadable"
    done

    echo; echo "=== Lockdown would stop (workloads using pool PVs) ==="
    using_pool deployment,statefulset,cronjob | jq -r '"\(.kind | ascii_downcase) \(.metadata.namespace)/\(.metadata.name)"' ||
        echo "Cannot query Kubernetes (KUBECONFIG=$KUBECONFIG)"
    printf 'timer %s\n' "${LOCKDOWN_TIMERS[@]}"
}

mark_failed() {
    [[ $DRY_RUN == 1 ]] || printf 'FAILED\n%s\n%s\n' "$(date)" "$1" > "$STATE_FILE"
}

# smartd runs this through /etc/smartmontools/run.d. Other fail types (ErrorCount is often cabling) only log.
handle_smartd() {
    local dev i reason
    dev=$(basename "$(readlink -f "${SMARTD_DEVICE:-none}")")
    for i in "${!MOUNTS[@]}"; do
        [[ ${DISKS[$i]} == "$dev" ]] || continue
        reason="smartd ${SMARTD_FAILTYPE:-?} on ${MOUNTS[$i]} (${SERIALS[$i]}): ${SMARTD_MESSAGE:-}"
        case "${SMARTD_FAILTYPE:-}" in
            Health|CurrentPendingSector|OfflineUncorrectableSector|SelfTest)
                error "$reason"
                mark_failed "$reason"
                export_disk_metrics 0
                lockdown_array
                return
                ;;
        esac
        warn "$reason (no lockdown for this type)"
        return 0
    done
    info "smartd ${SMARTD_FAILTYPE:-?} on ${SMARTD_DEVICE:-?} is not an array disk; ignoring"
}

main() {
    if [[ ${1:-check} =~ ^(check|lockdown|smartd)$ ]]; then
        mkdir -p "$STATE_DIR"
        exec 9> /run/disk-monitor.lock
        flock 9
    fi
    case "${1:-check}" in
        check)
            discover_array
            check_all_drives || exit 1
            check_nfs_export_layer || exit 1
            ;;
        lockdown)
            discover_array
            mark_failed "Manual lockdown: ${2:-no reason given}"
            lockdown_array
            ;;
        smartd)
            discover_array
            handle_smartd
            ;;
        status)
            discover_array
            show_status
            ;;
        *)
            cat <<EOF
Usage: $0 {check|status|lockdown [reason]|smartd}

  check     Health check; locks the array down on any drive failure (default)
  status    Show drives, NFS exports, and what a lockdown would stop
  lockdown  Lock down now. DRY_RUN=1 logs the actions without doing them
  smartd    Hook for smartd; reads SMARTD_DEVICE and SMARTD_FAILTYPE

Lockdown: disables ${LOCKDOWN_TIMERS[*]}, scales to 0 / suspends every workload
with a PVC on the pool, sets the mergerfs branches read-only, remounts all
SnapRAID disks read-only. Undo commands are written to $RESTORE_FILE.
EOF
            exit 1
            ;;
    esac
}

main "$@"
