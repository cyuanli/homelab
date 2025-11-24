#!/bin/bash
# SnapRAID metrics export script
# Exports SnapRAID status to Prometheus

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

# Load configuration
load_config

LOG_FILE="/var/log/snapraid.log"

export_snapraid_metrics() {
    local status="$1"  # 1=success, 0=failed
    local timestamp=$(get_timestamp)
    local metrics_content=""

    # SnapRAID run status
    metrics_content+=$(export_gauge "snapraid_last_run_status" "$status" "" "Last SnapRAID run status (1=success, 0=failed)")
    metrics_content+=$'\n'

    # Last run timestamp
    metrics_content+=$(export_gauge "snapraid_last_run_timestamp_seconds" "$timestamp" "" "Last SnapRAID run timestamp")
    metrics_content+=$'\n'

    # Write metrics to file
    write_metric_file "snapraid.prom" "$metrics_content"
}

# Get last few lines of log to check status
LAST_LINES=$(tail -20 "$LOG_FILE" 2>/dev/null || echo "")

# Check if sync failed
if echo "$LAST_LINES" | grep -q "FAILED\|ERROR\|DANGER\|Run failed"; then
    echo "SnapRAID sync failed - exporting metrics"
    export_snapraid_metrics 0
    exit 0
fi

# Success
echo "SnapRAID sync completed successfully - exporting metrics"
export_snapraid_metrics 1
