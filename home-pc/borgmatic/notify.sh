#!/usr/bin/env bash
# Borgmatic backup notification script
set -euo pipefail

WEBHOOK_URL="${BORGMATIC_WEBHOOK_URL:-}"
SERVICE_RESULT="${1:-unknown}"
HOSTNAME="$(hostname)"

send_discord_notification() {
    local message="$1"
    local severity="$2"

    if [ -z "$WEBHOOK_URL" ]; then
        echo "No webhook URL configured" >&2
        return 1
    fi

    local emoji
    case "$severity" in
        "ERROR") emoji=":rotating_light:" ;;
        "SUCCESS") emoji=":white_check_mark:" ;;
        *) emoji=":information_source:" ;;
    esac

    # Escape message for JSON
    local escaped_message
    escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')

    if curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"$emoji **Borgmatic Backup [$severity] on $HOSTNAME**\\n\\n$escaped_message\"}" "$WEBHOOK_URL" >/dev/null 2>&1; then
        echo "Discord notification sent successfully"
        return 0
    else
        echo "Failed to send Discord notification" >&2
        return 1
    fi
}

case "$SERVICE_RESULT" in
    "exit-code")
        # Get recent borgmatic logs
        recent_logs=$(journalctl -u borgmatic.service --since="1 hour ago" --no-pager -n 20 | tail -10)

        message="Borgmatic backup FAILED at $(date)

Recent log entries:
\`\`\`
$recent_logs
\`\`\`

Check full logs with: journalctl -u borgmatic.service"

        send_discord_notification "$message" "ERROR"
        ;;
    "success")
        message="Borgmatic backup completed successfully at $(date)"
        send_discord_notification "$message" "SUCCESS"
        ;;
    *)
        echo "Unknown service result: $SERVICE_RESULT" >&2
        exit 1
        ;;
esac