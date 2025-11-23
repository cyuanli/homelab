#!/bin/bash
# SnapRAID notification script
# Sends Discord alerts when SnapRAID sync fails

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

# Load configuration
load_config

# Use Discord webhook from config
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LOG_FILE="/var/log/snapraid.log"

if [ -z "$WEBHOOK_URL" ]; then
    echo "ERROR: No Discord webhook URL configured"
    exit 1
fi

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
LAST_LINES=$(tail -20 "$LOG_FILE")

# Check if sync failed
if echo "$LAST_LINES" | grep -q "FAILED\|ERROR\|DANGER\|Run failed"; then
    # Extract error details
    ERROR_MSG=$(echo "$LAST_LINES" | grep -E "FAILED|ERROR|DANGER|threshold|Run failed" | tail -5)

    # Send Discord notification
    curl -H "Content-Type: application/json" \
         -d "{\"content\": \"🚨 **SnapRAID FAILED on $(hostname)**\n\`\`\`\n$ERROR_MSG\n\`\`\`\n\nCheck logs: \`tail -50 /var/log/snapraid.log\`\"}" \
         "$WEBHOOK_URL"

    echo "SnapRAID failure notification sent"
    export_snapraid_metrics 0
    exit 0
fi

# Success - optionally send success notification (disabled by default)
# Uncomment to get notified on every successful sync
# curl -H "Content-Type: application/json" \
#      -d "{\"content\": \"✅ **SnapRAID sync completed successfully** on $(hostname)\"}" \
#      "$WEBHOOK_URL"

echo "SnapRAID sync completed successfully"
export_snapraid_metrics 1
