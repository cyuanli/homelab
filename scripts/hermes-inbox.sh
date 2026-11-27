#!/usr/bin/env bash
# Answers messages Hermes leaves in its inbox with read-only headless Claude Code, replying over peer dm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"
# shellcheck source=utils/claude-headless.sh
source "$SCRIPT_DIR/utils/claude-headless.sh"

CONF="$REPO/config/hermes-inbox"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/hermes-inbox}"
RUN_TIMEOUT="${RUN_TIMEOUT:-15m}"
MAX_MESSAGES="${MAX_MESSAGES:-3}"
MAX_BYTES=20000
INBOX=/opt/data/claude-inbox

usage() {
    cat << EOF
Usage: $0 [--dry-run | --list]

Reads up to $MAX_MESSAGES of the oldest messages in Hermes's $INBOX/new,
lets Claude Code reply over peer dm, then moves them to done/.

  --list     list pending messages
  --dry-run  show the prompt that would be sent, run nothing, archive nothing
EOF
}

mode=run
case "${1:-}" in
    "") ;;
    --dry-run) mode=dry ;;
    --list) mode=list ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac

in_pod() {
    kubectl -n ai exec deploy/hermes -c hermes -- /command/s6-setuidgid hermes "$@" 2> >(grep -v 'install out of sync' >&2)
}

# Skips files touched in the last minute, Hermes may still be writing them
pending() {
    in_pod find "$INBOX/new" -maxdepth 1 -type f -regex '.*/[A-Za-z0-9][A-Za-z0-9._-]*' -mmin +1 -printf '%T@ %f\n' \
        | sort -n | cut -d' ' -f2-
}

in_pod mkdir -p "$INBOX/new" "$INBOX/done"

if [[ "$mode" == list ]]; then
    pending
    exit 0
fi

mkdir -p "$STATE_DIR/runs"
exec 9> "$STATE_DIR/lock"
flock -n 9 || { log_info "Another run is in progress"; exit 0; }
find "$STATE_DIR/runs" -type f -mtime +30 -delete

mapfile -t files < <(pending | head -n "$MAX_MESSAGES")
[[ ${#files[@]} -eq 0 ]] && exit 0

context="Hermes left these messages in your inbox, oldest first:"
for f in "${files[@]}"; do
    context+="

===== $f =====
$(in_pod head -c "$MAX_BYTES" "$INBOX/new/$f")
===== end of $f ====="
done

if [[ "$mode" == dry ]]; then
    echo "$context"
    exit 0
fi

log_info "Answering: ${files[*]}"
run_id="$(date +%Y%m%dT%H%M%S)"
started="$(date +%s)"
rc=0
GUARD_EXTENSION="$CONF/reply-rule.sh" HERMES_INBOX_STATE="$STATE_DIR" \
    claude_headless "$RUN_TIMEOUT" "$CONF/prompt.md" "$context" "$STATE_DIR/runs/$run_id.json" "$STATE_DIR/runs/$run_id.stderr" \
    --allowedTools "Bash(scripts/hermes-reply.sh:*)" || rc=$?
elapsed="$(( $(date +%s) - started ))s"
out="$(cat "$STATE_DIR/runs/$run_id.json")"

result="$(jq -r '.result // empty' <<< "$out" 2> /dev/null || true)"
session="$(jq -r '.session_id // empty' <<< "$out" 2> /dev/null || true)"
is_error="$(jq -r '.is_error // false' <<< "$out" 2> /dev/null || echo true)"
rm -f "$STATE_DIR/replies-$session"

if [[ "$rc" -ne 0 || "$is_error" == true || -z "$result" ]]; then
    reason="exit code $rc"
    [[ "$rc" -eq 124 ]] && reason="timed out after $RUN_TIMEOUT"
    # Left in new/, retried next tick
    echo "$(date -Is) FAILED ($reason, $elapsed) ${files[*]} · logs: runs/$run_id.*" >> "$STATE_DIR/log"
    log_error "Run failed ($reason), see $STATE_DIR/runs/$run_id.stderr"
    exit 1
fi

for f in "${files[@]}"; do
    in_pod mv "$INBOX/new/$f" "$INBOX/done/$f"
done
{
    echo "$(date -Is) ${files[*]} ($elapsed, resume: cd ~/homelab && claude -r $session)"
    sed 's/^/    /' <<< "$result"
} >> "$STATE_DIR/log"
log_success "Answered: ${files[*]}"
