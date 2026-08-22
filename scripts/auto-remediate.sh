#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/common.sh"

COOLDOWN_SECONDS=3600
ALERTMANAGER_LOCAL_PORT=9093
PORTFORWARD_PID=""

# subdomain -> deployment:namespace
declare -A SERVICE_MAP=(
    [drive]="nextcloud:cloud"
    [photos]="immich-server:cloud"
    [jellyfin]="jellyfin:media"
    [owntracks]="owntracks:location"
    [prowlarr]="prowlarr:media"
    [qbittorrent]="qbittorrent:media"
    [radarr]="radarr:media"
    [sonarr]="sonarr:media"
    [whoami]="whoami:utilities"
)

cleanup() {
    if [[ -n "$PORTFORWARD_PID" ]] && kill -0 "$PORTFORWARD_PID" 2>/dev/null; then
        kill "$PORTFORWARD_PID" 2>/dev/null
        wait "$PORTFORWARD_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

check_cooldown() {
    local deployment="$1"
    local cooldown_file="/tmp/auto-remediate-${deployment}.last"

    if [[ -f "$cooldown_file" ]]; then
        local last_restart
        last_restart=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        local elapsed=$((now - last_restart))
        if [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
            local remaining=$(( (COOLDOWN_SECONDS - elapsed) / 60 ))
            log_info "Skipping $deployment — cooldown active (${remaining}m remaining)"
            return 1
        fi
    fi
    return 0
}

set_cooldown() {
    local deployment="$1"
    date +%s > "/tmp/auto-remediate-${deployment}.last"
}

log_info "Starting port-forward to alertmanager-operated"
kubectl port-forward -n monitoring svc/alertmanager-operated "$ALERTMANAGER_LOCAL_PORT":9093 &>/dev/null &
PORTFORWARD_PID=$!
sleep 2

if ! kill -0 "$PORTFORWARD_PID" 2>/dev/null; then
    log_error "Failed to start port-forward to alertmanager"
    exit 0 # avoid timer backoff
fi

log_info "Querying Alertmanager for active ServiceDown alerts"
ALERTS_JSON=$(curl -sf "http://localhost:${ALERTMANAGER_LOCAL_PORT}/api/v2/alerts?filter=alertname%3D%22ServiceDown%22&active=true" 2>/dev/null) || {
    log_error "Failed to query Alertmanager API"
    exit 0
}

cleanup
PORTFORWARD_PID=""

ALERT_COUNT=$(echo "$ALERTS_JSON" | jq 'length')
if [[ "$ALERT_COUNT" -eq 0 ]]; then
    log_info "No active ServiceDown alerts"
    exit 0
fi

log_warning "Found $ALERT_COUNT active ServiceDown alert(s)"

echo "$ALERTS_JSON" | jq -r '.[].labels.instance // empty' | while read -r instance_url; do
    subdomain=$(echo "$instance_url" | sed -E 's|https?://([^.]+)\..*|\1|')

    if [[ -z "$subdomain" ]]; then
        log_warning "Could not extract subdomain from: $instance_url"
        continue
    fi

    mapping="${SERVICE_MAP[$subdomain]:-}"
    if [[ -z "$mapping" ]]; then
        log_info "No mapping for subdomain '$subdomain' — skipping (monitoring/infra or unknown)"
        continue
    fi

    deployment="${mapping%%:*}"
    namespace="${mapping##*:}"

    if ! check_cooldown "$deployment"; then
        continue
    fi

    log_warning "Restarting deployment/$deployment in namespace $namespace (alert instance: $instance_url)"
    if kubectl rollout restart "deployment/$deployment" -n "$namespace"; then
        set_cooldown "$deployment"
        log_success "Successfully restarted deployment/$deployment in namespace $namespace"
    else
        log_error "Failed to restart deployment/$deployment in namespace $namespace"
    fi
done

log_info "Auto-remediation complete"
exit 0
