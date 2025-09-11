#!/bin/bash

# Cron wrapper for disk monitoring with Discord webhook configuration
# This script sources the webhook URL and runs the disk monitor

set -euo pipefail

# Set PATH for cron environment (includes system binaries)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Get the actual script directory (not symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/disk-monitor.conf"
LOG_FILE="/var/log/disk-monitor.log"

# Source configuration if it exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Config loaded, webhook URL: ${DISK_MONITOR_WEBHOOK:0:50}..." >> "$LOG_FILE" 2>/dev/null || true
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Config file $CONFIG_FILE not found" >> "$LOG_FILE" 2>/dev/null || true
fi

# Export webhook URL for the main script
export DISK_MONITOR_WEBHOOK="${DISK_MONITOR_WEBHOOK:-}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Exported webhook URL: ${DISK_MONITOR_WEBHOOK:0:50}..." >> "$LOG_FILE" 2>/dev/null || true

# Run the main disk monitor script
exec "$SCRIPT_DIR/disk-monitor.sh" check