#!/usr/bin/env bash
# borgmatic before_backup hook. borgmatic archives only file trees under
# /media/data, and Nextcloud/Immich files are unrestorable without their DBs.
# Always exits 0: one unreachable DB must not abort the whole run, failures
# surface as metrics instead (DatabaseDumpFailed / DatabaseDumpStale).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

# Must sit under a borgmatic source_directory or dumps never get archived.
DUMP_DIR="${DUMP_DIR:-/media/data/db-dumps}"

# Mirrors borgmatic.service, for manual sudo runs where the invoking user's
# ~/.kube/config is out of reach.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# name|namespace|pod selector|postgres user|database name
DATABASES=(
    "immich|cloud|app=immich-postgres|immich|immich"
    "nextcloud|cloud|app=postgres|nextcloud|nextcloud"
)

# Grouped per family, not per database: node_exporter drops the whole file if
# samples of a family are interleaved.
SUCCESS_LINES=""
SIZE_LINES=""
TIMESTAMP_LINES=""

# Terminating pods still report phase=Running, so deletionTimestamp must be
# filtered too. Keep stderr: without it a dead kubeconfig, an unreachable API
# and an absent pod all look identical. Errors go to POD_ERROR because log_*
# writes to stdout, which $(...) would splice into the returned pod name.
POD_ERROR=""
find_postgres_pod() {
    local namespace="$1" selector="$2"
    local out
    POD_ERROR=""

    if ! out="$(kubectl get pod -n "$namespace" -l "$selector" \
        -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>&1)"; then
        # Actionable message is the last one, after klog E-prefixed noise.
        POD_ERROR="$(printf '%s\n' "$out" | grep -v '^E[0-9]\{4\} ' | tail -1)"
        return 1
    fi

    printf '%s\n' "$out" | head -1
}

record() {
    local name="$1" status="$2"

    local target="$DUMP_DIR/${name}.sql"

    local size=0
    [[ -f "$target" ]] && size="$(stat -c %s "$target")"

    SUCCESS_LINES+=$(export_gauge_line "homelab_db_dump_success" "$status" "database=\"$name\"")
    SUCCESS_LINES+=$'\n'
    SIZE_LINES+=$(export_gauge_line "homelab_db_dump_size_bytes" "$size" "database=\"$name\"")
    SIZE_LINES+=$'\n'

    # mtime of the file on disk, never "now", and emitted on failure too, or
    # DatabaseDumpStale stops firing exactly when it matters. Missing file
    # reports 0, which still trips the alert.
    local mtime=0
    [[ -f "$target" ]] && mtime="$(stat -c %Y "$target")"
    TIMESTAMP_LINES+=$(export_gauge_line "homelab_db_dump_timestamp_seconds" "$mtime" "database=\"$name\"")
    TIMESTAMP_LINES+=$'\n'
}

dump_database() {
    local name="$1" namespace="$2" selector="$3" user="$4" dbname="$5"
    local target="$DUMP_DIR/${name}.sql"
    local partial="${target}.part"

    log_info "Dumping database '$name' ($namespace/$dbname)"

    local pod
    if ! pod="$(find_postgres_pod "$namespace" "$selector")"; then
        log_error "kubectl lookup failed for '$name': $POD_ERROR"
        record "$name" 0
        return 1
    fi
    if [[ -z "$pod" ]]; then
        log_error "No running postgres pod for '$name' (selector: $selector in $namespace)"
        record "$name" 0
        return 1
    fi

    # Uncompressed: borg applies zstd itself and dedupes a plain dump far
    # better than a gzip stream, where one changed row perturbs everything.
    if ! kubectl exec -n "$namespace" "$pod" -- \
        pg_dump --clean --if-exists --username="$user" --dbname="$dbname" > "$partial" 2>/dev/null; then
        log_error "pg_dump failed for '$name' (pod $pod) - keeping previous dump"
        rm -f "$partial"
        record "$name" 0
        return 1
    fi

    # pg_dump exits 0 on a mid-stream disconnect, so trust the trailer, not the
    # exit code. A truncated dump must never replace a good one.
    if ! tail -5 "$partial" | grep -q "PostgreSQL database dump complete"; then
        log_error "Dump for '$name' is truncated (no completion marker) - keeping previous dump"
        rm -f "$partial"
        record "$name" 0
        return 1
    fi

    local size
    size="$(stat -c %s "$partial")"

    chmod 600 "$partial"
    mv "$partial" "$target"

    log_success "Dumped '$name' ($(numfmt --to=iec "$size"))"
    record "$name" 1
    return 0
}

main() {
    if ! command_exists kubectl; then
        log_error "kubectl not found - cannot dump databases"
        exit 0
    fi

    # Probed up front so the log names the real fault instead of reporting
    # every database as individually missing.
    local api_ok=1 api_err
    if ! api_err="$(kubectl get --raw='/readyz' 2>&1 | grep -v '^E[0-9]\{4\} ' | tail -1)"; then
        api_ok=0
    elif [[ "$api_err" != "ok" ]]; then
        api_ok=0
    fi

    if [[ $api_ok -eq 0 ]]; then
        log_error "Cannot reach the Kubernetes API - no databases can be dumped"
        log_error "  kubectl: $api_err"
        log_error "  KUBECONFIG=${KUBECONFIG:-<unset>}, running as $(id -un)"
    fi

    # 0700: dumps hold every password hash and session token. /media/data is
    # NFS-exported with no_root_squash, so any node root can still read them.
    mkdir -p "$DUMP_DIR"
    chmod 700 "$DUMP_DIR"

    local failed=0
    for entry in "${DATABASES[@]}"; do
        IFS='|' read -r name namespace selector user dbname <<< "$entry"

        # Record the failure for alerting, skip the doomed kubectl calls that
        # would bury the real cause under klog output.
        if [[ $api_ok -eq 0 ]]; then
            log_error "Skipping '$name' - Kubernetes API unreachable"
            record "$name" 0
            failed=$((failed + 1))
            continue
        fi

        dump_database "$name" "$namespace" "$selector" "$user" "$dbname" || failed=$((failed + 1))
    done

    local content=""
    content+=$(export_gauge_header "homelab_db_dump_success" "Whether the last database dump attempt succeeded (1=success, 0=failed)")
    content+=$'\n'
    content+="$SUCCESS_LINES"
    content+=$(export_gauge_header "homelab_db_dump_size_bytes" "Size in bytes of the database dump currently on disk")
    content+=$'\n'
    content+="$SIZE_LINES"
    content+=$(export_gauge_header "homelab_db_dump_timestamp_seconds" "Modification time of the database dump currently on disk (0=no dump)")
    content+=$'\n'
    content+="$TIMESTAMP_LINES"

    write_metric_file "db-dumps.prom" "$content"

    if [[ $failed -gt 0 ]]; then
        log_warning "$failed of ${#DATABASES[@]} database dumps failed - backup continues with the previous dump(s)"
    else
        log_success "All ${#DATABASES[@]} database dumps completed"
    fi

    # Deliberately 0, see header.
    exit 0
}

main "$@"
