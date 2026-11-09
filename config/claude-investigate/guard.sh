#!/usr/bin/env bash
# PreToolUse hook for claude-investigate: second line of defence behind the read-only allowlist.
set -uo pipefail

input="$(cat)"
tool="$(jq -r '.tool_name // ""' <<< "$input")"

block() {
    echo "Blocked by claude-investigate guard: $1" >&2
    exit 2
}

sensitive='secret|passphrase|vault|\.env\b|env\.local|token|password|credential|\.ssh|id_rsa|id_ed25519|\.kube/|/etc/rancher|\.claude/'

case "$tool" in
    Bash)
        cmd="$(jq -r '.tool_input.command // ""' <<< "$input")"
        grep -qiP "$sensitive" <<< "$cmd" && block "touches credentials"
        grep -qP '\$\(|`' <<< "$cmd" && block "command substitution"
        grep -qP '(^|[^0-9&>])>(?!\s*/dev/null)' <<< "$cmd" && block "output redirection"
        grep -qiP '(^|[\s;&|(])(sudo|su|rm|mv|cp|dd|tee|chmod|chown|ln|mkdir|touch|truncate|kill|pkill|reboot|shutdown|curl|wget|ssh|scp|rsync|nc|bash|sh|zsh|python3?|perl|ruby|node|xargs|env|eval|source|exec|helm|crontab)\b' <<< "$cmd" \
            && block "command not allowed in read-only mode"
        # Settings allow all of kubectl, so every invocation's verb must be a read verb
        while read -r verb; do
            [[ "$verb" =~ ^(get|describe|logs|top|events|explain|api-resources|api-versions|version)$ ]] \
                || block "kubectl verb '${verb:-none}' not allowed in read-only mode"
        done < <(grep -oP '\bkubectl\b[^;&|]*' <<< "$cmd" | awk '{
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^(-n|--namespace|--context|--cluster|--user|-s|--server|--request-timeout)$/) { i++; continue }
                if ($i ~ /^-/) continue
                print $i; next
            }
            print ""
        }')
        grep -qiP '\bsystemctl\s+(?!status|list-)' <<< "$cmd" && block "systemctl write operation"
        grep -qiP '\bgit\s+(?!log|diff|status|show|blame)' <<< "$cmd" && block "git write operation"
        ;;
    Read|Grep|Glob)
        target="$(jq -r '[.tool_input.file_path, .tool_input.path, .tool_input.pattern, .tool_input.glob] | map(select(. != null)) | join(" ")' <<< "$input")"
        grep -qiP "$sensitive" <<< "$target" && block "touches credentials"
        ;;
esac
exit 0
