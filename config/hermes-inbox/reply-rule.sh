#!/usr/bin/env bash
# GUARD_EXTENSION for hermes-inbox: allows scripts/hermes-reply.sh with one single-quoted argument, up to MAX_REPLIES per run.
set -uo pipefail

MAX_REPLIES="${MAX_REPLIES:-8}"

input="$(cat)"
[[ "$(jq -r '.tool_name // ""' <<< "$input")" == Bash ]] || exit 1
cmd="$(jq -r '.tool_input.command // ""' <<< "$input")"
[[ "$cmd" == *hermes-reply* ]] || exit 1

block() {
    echo "Blocked by hermes-inbox reply rule: $1" >&2
    exit 2
}

# Single quotes, with '\'' for a literal quote, so bash expands nothing in the message
re="^scripts/hermes-reply\.sh '([^']|'\\\\'')*'\$"
[[ "$cmd" =~ $re ]] || block "use exactly: scripts/hermes-reply.sh '<message>' (single quotes, '\\'' for a quote, nothing else in the call)"

[[ -n "${HERMES_INBOX_STATE:-}" ]] || block "HERMES_INBOX_STATE not set"
session="$(jq -r '.session_id // "unknown"' <<< "$input" | tr -cd 'A-Za-z0-9-')"
counter="$HERMES_INBOX_STATE/replies-$session"
n=$(( $(cat "$counter" 2> /dev/null || echo 0) + 1 ))
[[ "$n" -le "$MAX_REPLIES" ]] || block "reply limit ($MAX_REPLIES) reached for this run, wrap up"
echo "$n" > "$counter"
exit 0
