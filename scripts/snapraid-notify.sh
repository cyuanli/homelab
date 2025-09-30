#!/bin/bash
# SnapRAID notification script
# Sends Discord alerts when SnapRAID sync fails

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# Load configuration
load_config

# Use Discord webhook from config
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LOG_FILE="/var/log/snapraid.log"

if [ -z "$WEBHOOK_URL" ]; then
    echo "ERROR: No Discord webhook URL configured"
    exit 1
fi

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
    exit 0
fi

# Success - optionally send success notification (disabled by default)
# Uncomment to get notified on every successful sync
# curl -H "Content-Type: application/json" \
#      -d "{\"content\": \"✅ **SnapRAID sync completed successfully** on $(hostname)\"}" \
#      "$WEBHOOK_URL"

echo "SnapRAID sync completed successfully"
