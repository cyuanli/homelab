#!/usr/bin/env bash
# Headless Claude Code under the shared read-only policy in config/claude-readonly.

CLAUDE_HEADLESS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE="${CLAUDE:-$HOME/.local/bin/claude}"

# Usage: claude_headless <timeout> <job-prompt-file> <prompt> <out-json> <stderr-file> [extra claude args...]
# Runs in the repo with the shared prompt followed by the job's. Returns claude's exit code (124 on timeout).
claude_headless() {
    local timeout="$1" job_prompt="$2" prompt="$3" out="$4" err="$5"
    shift 5
    local system_prompt
    system_prompt="$(cat "$CLAUDE_HEADLESS_REPO/config/claude-readonly/prompt.md" "$job_prompt")"
    (cd "$CLAUDE_HEADLESS_REPO" && timeout --kill-after=30s "$timeout" "$CLAUDE" -p "$prompt" \
        --output-format json \
        --setting-sources user \
        --settings "$CLAUDE_HEADLESS_REPO/config/claude-readonly/settings.json" \
        --permission-mode dontAsk \
        --permission-prompts none \
        --strict-mcp-config \
        --disable-slash-commands \
        --append-system-prompt "$system_prompt" \
        "$@") > "$out" 2> "$err"
}
