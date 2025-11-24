#!/usr/bin/env bash
# Borgmatic backup metrics export script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

SERVICE_RESULT="${1:-unknown}"
HOSTNAME="$(hostname)"

# Load configuration
load_config

export_borgmatic_metrics() {
    local status="$1"  # 1=success, 0=failed
    local timestamp=$(get_timestamp)
    local metrics_content=""

    # Backup status
    metrics_content+=$(export_gauge "borgmatic_last_run_status" "$status" "" "Last Borgmatic backup status (1=success, 0=failed)")
    metrics_content+=$'\n'

    # Last run timestamp
    metrics_content+=$(export_gauge "borgmatic_last_run_timestamp_seconds" "$timestamp" "" "Last Borgmatic backup run timestamp")
    metrics_content+=$'\n'

    # Write metrics to file
    write_metric_file "borgmatic.prom" "$metrics_content"
}

case "$SERVICE_RESULT" in
    "exit-code")
        log_error "Borgmatic backup FAILED at $(date)"
        log_info "Check full logs with: journalctl -u borgmatic.service"
        export_borgmatic_metrics 0
        ;;
    "error")
        log_error "Borgmatic hook or action FAILED at $(date)"
        log_info "Check full logs with: journalctl -u borgmatic.service"
        export_borgmatic_metrics 0
        ;;
    "success")
        log_info "Borgmatic backup completed successfully at $(date)"
        export_borgmatic_metrics 1
        ;;
    *)
        log_error "Unknown service result: $SERVICE_RESULT"
        exit 1
        ;;
esac