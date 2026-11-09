#!/usr/bin/env bash
# Investigates new firing alerts with Claude Code (read-only, phase 1) and posts every run to Discord.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

CONF="$REPO/config/claude-investigate"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-investigate}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-21600}"
RUN_TIMEOUT="${RUN_TIMEOUT:-20m}"
CLAUDE="${CLAUDE:-$HOME/.local/bin/claude}"
IGNORE_ALERTS='^(Watchdog|InfoInhibitor)$'
AM_PATH="${AM_PATH:-/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false}"

usage() {
    cat << EOF
Usage: $0 [--dry-run] [--force]

Runs Claude Code read-only on Alertmanager alerts not investigated in the last
$((COOLDOWN_SECONDS / 3600))h and posts the report to Discord.

  --dry-run  show what would be investigated, run nothing, post nothing
  --force    ignore the per-alert cooldown
EOF
}

dry_run=false
force=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR/runs"
exec 9> "$STATE_DIR/lock"
flock -n 9 || { log_info "Another run is in progress"; exit 0; }

seen_file="$STATE_DIR/seen.json"
[[ -f "$seen_file" ]] || echo '{}' > "$seen_file"
now="$(date +%s)"
cooldown="$COOLDOWN_SECONDS"
$force && cooldown=0

webhook_url() {
    local cache="$STATE_DIR/webhook-url"
    if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        echo "$DISCORD_WEBHOOK_URL"
    elif url="$(kubectl -n monitoring get secret alertmanager-discord-webhook -o jsonpath='{.data.webhook-url}' 2> /dev/null | base64 -d)" && [[ -n "$url" ]]; then
        (umask 077; echo "$url" > "$cache")
        echo "$url"
    else
        # Cached so a report can still go out while the API server is down
        cat "$cache"
    fi
}

post_discord() {
    local title="$1" body="$2" color="$3" footer="$4"
    jq -n --arg t "${title:0:250}" --arg d "${body:0:4000}" --argjson c "$color" --arg f "${footer:0:2000}" \
        '{allowed_mentions: {parse: []}, embeds: [{title: $t, description: $d, color: $c, footer: {text: $f}}]}' \
        | curl -fsS -m 30 -H 'Content-Type: application/json' -d @- "$(webhook_url)" > /dev/null
}

find "$STATE_DIR/runs" -type f -mtime +30 -delete

if alerts="$(kubectl get --raw "$AM_PATH" 2> "$STATE_DIR/am.stderr")"; then
    new="$(jq --slurpfile seen "$seen_file" --argjson now "$now" --argjson cd "$cooldown" --arg ign "$IGNORE_ALERTS" '
        [.[] | select(.labels.alertname | test($ign) | not)
             | select(($seen[0][.fingerprint] // 0) <= $now - $cd)
             | {fingerprint, startsAt, labels, annotations}]' <<< "$alerts")"
    [[ "$(jq length <<< "$new")" -eq 0 ]] && exit 0
    keys="$(jq -c '[.[].fingerprint]' <<< "$new")"
    names="$(jq -r '[.[].labels.alertname] | unique | join(", ")' <<< "$new")"
    context="These alerts are firing and haven't been investigated recently:

$(jq . <<< "$new")"
else
    key="alertmanager-unreachable"
    [[ "$(jq --arg k "$key" --argjson now "$now" --argjson cd "$cooldown" '(.[$k] // 0) <= $now - $cd' "$seen_file")" == true ]] || exit 0
    keys="[\"$key\"]"
    names="Alertmanager unreachable"
    context="Alertmanager can't be reached from cyl-homelab through the API server proxy, so alerts can't be read. The request failed with:

$(head -c 2000 "$STATE_DIR/am.stderr")"
fi

if $dry_run; then
    log_info "Would investigate: $names"
    echo "$context"
    exit 0
fi

# Marked before the run so a crash or timeout doesn't retrigger every interval
tmp="$(mktemp "$STATE_DIR/seen.XXXXXX")"
jq --argjson keys "$keys" --argjson now "$now" --argjson max "$((COOLDOWN_SECONDS * 4))" '
    with_entries(select(.value > $now - $max)) + ($keys | map({(.): $now}) | add)' "$seen_file" > "$tmp"
mv "$tmp" "$seen_file"

log_info "Investigating: $names"
run_id="$(date +%Y%m%dT%H%M%S)"
started="$(date +%s)"
rc=0
out="$(cd "$REPO" && timeout --kill-after=30s "$RUN_TIMEOUT" "$CLAUDE" -p "$context" \
    --output-format json \
    --setting-sources user \
    --settings "$CONF/settings.json" \
    --permission-mode dontAsk \
    --permission-prompts none \
    --strict-mcp-config \
    --disable-slash-commands \
    --append-system-prompt-file "$CONF/prompt.md" \
    2> "$STATE_DIR/runs/$run_id.stderr")" || rc=$?
elapsed="$(( $(date +%s) - started ))s"
echo "$out" > "$STATE_DIR/runs/$run_id.json"

result="$(jq -r '.result // empty' <<< "$out" 2> /dev/null || true)"
session="$(jq -r '.session_id // empty' <<< "$out" 2> /dev/null || true)"
turns="$(jq -r '.num_turns // "?"' <<< "$out" 2> /dev/null || echo '?')"
is_error="$(jq -r '.is_error // false' <<< "$out" 2> /dev/null || echo true)"

footer="cyl-homelab · ${elapsed} · ${turns} turns"
[[ -n "$session" ]] && footer+=" · resume: cd ~/homelab && claude -r $session"

if [[ "$rc" -eq 0 && "$is_error" != true && -n "$result" ]]; then
    post_discord "🔎 Claude investigated: $names" "$result" 5793266 "$footer"
    log_success "Report posted for: $names"
else
    reason="exit code $rc"
    [[ "$rc" -eq 124 ]] && reason="timed out after $RUN_TIMEOUT"
    detail="$(tail -c 1500 "$STATE_DIR/runs/$run_id.stderr")"
    [[ -n "$result" ]] && detail="$result"
    post_discord "⚠️ Claude investigation failed: $names" "Run failed ($reason).
\`\`\`
${detail:-no output}
\`\`\`
Logs: $STATE_DIR/runs/$run_id.*" 15548997 "$footer"
    log_error "Investigation failed ($reason)"
    exit 1
fi
