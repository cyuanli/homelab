#!/usr/bin/env bash
# Exit: 0 nothing firing, 1 alerts firing, 2 Alertmanager unreachable.
set -euo pipefail

NS="${ALERTMANAGER_NAMESPACE:-monitoring}"
SVC="${ALERTMANAGER_SERVICE:-kube-prometheus-stack-alertmanager:9093}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

usage() {
    cat << EOF
Usage: $0 [-a] [-j]

Show active Alertmanager alerts and silences.

  -a  also show silenced and inhibited alerts
  -j  print raw alert JSON instead of a summary
EOF
}

show_all=false
raw=false
while getopts "ajh" opt; do
    case "$opt" in
        a) show_all=true ;;
        j) raw=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

command -v jq > /dev/null || { log_error "jq is required"; exit 2; }

am_get() {
    kubectl get --raw "/api/v1/namespaces/$NS/services/$SVC/proxy/api/v2/$1" 2> /dev/null
}

if ! alerts="$(am_get alerts)"; then
    log_error "Cannot reach Alertmanager ($NS/$SVC)"
    exit 2
fi
silences="$(am_get silences || echo '[]')"

if $raw; then
    echo "$alerts" | jq .
    exit 0
fi

filter='.[]'
$show_all || filter='.[] | select(.status.state == "active")'

firing="$(echo "$alerts" | jq '[.[] | select(.status.state == "active")] | length')"
suppressed="$(echo "$alerts" | jq '[.[] | select(.status.state != "active")] | length')"

log_step "Alertmanager alerts"
if [[ "$firing" -eq 0 ]] && ! $show_all; then
    log_success "No alerts firing ($suppressed silenced/inhibited, -a to show)"
else
    echo "$alerts" | jq -r "
        [$filter] | sort_by(
            (.labels.severity | {critical: 0, warning: 1, info: 2}[.] // 3),
            .labels.alertname
        ) | .[] |
        \"\(.labels.severity // \"none\" | ascii_upcase)\t\(.labels.alertname)\t\(.status.state)\tsince \(.startsAt[:16] | sub(\"T\"; \" \"))Z\t\(.labels.namespace // \"\")/\(.labels.pod // .labels.instance // .labels.job // \"\")\n    \(.annotations.summary // .annotations.description // .annotations.message // \"\" | gsub(\"\n\"; \" \"))\"
    "
    echo
    log_info "$firing firing, $suppressed silenced/inhibited"
fi

active_silences="$(echo "$silences" | jq '[.[] | select(.status.state == "active")]')"
if [[ "$(echo "$active_silences" | jq length)" -gt 0 ]]; then
    log_step "Active silences"
    echo "$active_silences" | jq -r '.[] |
        "\(.endsAt[:16] | sub("T"; " "))Z  \(.createdBy)  \(.comment)\n    \([.matchers[] | "\(.name)\(if .isEqual == false then "!" else "" end)\(if .isRegex then "=~" else "=" end)\(.value)"] | join(", "))"'
fi

[[ "$firing" -eq 0 ]]
