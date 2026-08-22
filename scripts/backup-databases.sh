#!/usr/bin/env bash
# Dump the cluster's PostgreSQL databases to disk so borgmatic can back them up.
#
# borgmatic only backs up file trees under /media/data. The Nextcloud and Immich
# *databases* live in PVCs and were never captured, which meant the file backups
# were unrestorable on their own: Nextcloud files without its DB have no users,
# shares or metadata, and an Immich library without its DB has no albums, faces
# or people.
#
# Run from borgmatic's before_backup hook. See docs/OPERATIONS.md.
#
# EXIT CODE: always 0 on a partial failure. A single unreachable database must
# not abort the whole backup run - the file trees are still worth capturing, and
# aborting would mean one offline node costs us every backup that night. Failures
# surface as Prometheus metrics instead (DatabaseDumpFailed / DatabaseDumpStale),
# and the previous good dump is left in place rather than being truncated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# shellcheck source=utils/metrics.sh
source "$SCRIPT_DIR/utils/metrics.sh"

# Must sit inside one of borgmatic's source_directories or the dumps never
# reach the repository.
DUMP_DIR="${DUMP_DIR:-/media/data/db-dumps}"

# borgmatic.service sets this itself, but the script also gets run by hand under
# sudo, where the invoking user's ~/.kube/config is out of reach and kubectl
# would otherwise find no configuration at all. Mirror the unit's value so both
# paths behave identically.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# name|namespace|pod selector|postgres user|database name
DATABASES=(
    "immich|cloud|app=immich-postgres|immich|immich"
    "nextcloud|cloud|app=postgres|nextcloud|nextcloud"
)

# Samples are collected per metric family, not per database. The Prometheus text
# format requires every sample of a family to be contiguous, and node_exporter's
# textfile collector drops the whole file if they are interleaved.
SUCCESS_LINES=""
SIZE_LINES=""
TIMESTAMP_LINES=""

# Resolve a single live postgres pod for a selector. Prints the pod name, or
# nothing if there is genuinely no running pod; returns non-zero only when
# kubectl itself failed, leaving the reason in POD_ERROR.
#
# Three details that each cost a debugging round:
#
#  - Terminating pods still report phase=Running. When a node goes unreachable
#    its pods sit that way indefinitely (cyl-aspiree17, 2026-08-22), so
#    filtering on phase alone hands back a pod that no longer answers exec.
#    Skipping anything with a deletionTimestamp is what makes this reliable.
#  - stderr is NOT discarded. Swallowing it makes an unusable kubeconfig, an
#    unreachable API server and an absent pod all look identical ("No running
#    postgres pod").
#  - The error goes into POD_ERROR rather than through log_error, because the
#    log_* helpers in common.sh write to stdout - logging from inside a
#    function whose stdout is captured by $(...) splices the message into the
#    returned pod name.
POD_ERROR=""
find_postgres_pod() {
    local namespace="$1" selector="$2"
    local out
    POD_ERROR=""

    if ! out="$(kubectl get pod -n "$namespace" -l "$selector" \
        -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>&1)"; then
        # kubectl prefixes real failures with several klog "Unhandled Error"
        # lines; the actionable message is the last one.
        POD_ERROR="$(printf '%s\n' "$out" | grep -v '^E[0-9]\{4\} ' | tail -1)"
        return 1
    fi

    printf '%s\n' "$out" | head -1
}

# Size and timestamp always describe the dump on disk, not this run's attempt,
# so a failed run reports the previous dump it fell back to.
record() {
    local name="$1" status="$2"

    local target="$DUMP_DIR/${name}.sql"

    local size=0
    [[ -f "$target" ]] && size="$(stat -c %s "$target")"

    SUCCESS_LINES+=$(export_gauge_line "homelab_db_dump_success" "$status" "database=\"$name\"")
    SUCCESS_LINES+=$'\n'
    SIZE_LINES+=$(export_gauge_line "homelab_db_dump_size_bytes" "$size" "database=\"$name\"")
    SIZE_LINES+=$'\n'

    # Always the mtime of the dump actually sitting on disk, never "now", and
    # emitted on failure too. Reporting the age of the real file is what makes
    # DatabaseDumpStale mean "the newest dump we hold for this database is N days
    # old". Dropping the series on failure would instead make the alert stop
    # firing at exactly the moment it matters, and a missing file reports 0 so
    # the staleness expression still trips rather than silently matching nothing.
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

    # --clean --if-exists matches the flags Immich documents for its own restore
    # path. Output stays uncompressed: borg applies zstd itself and dedupes an
    # uncompressed dump against the previous night's far better than a gzip
    # stream, where one changed row perturbs the whole file.
    if ! kubectl exec -n "$namespace" "$pod" -- \
        pg_dump --clean --if-exists --username="$user" --dbname="$dbname" > "$partial" 2>/dev/null; then
        log_error "pg_dump failed for '$name' (pod $pod) - keeping previous dump"
        rm -f "$partial"
        record "$name" 0
        return 1
    fi

    # pg_dump exits 0 on a connection dropped mid-stream, so trust the trailer
    # rather than the exit code. Promoting a truncated dump over a good one is
    # the failure mode that turns "we have backups" into "we had backups".
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

    # Distinguish "the cluster is unreachable" from "this database's pod is
    # down" up front, so the log names the actual fault instead of reporting
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

    # 0700: these dumps contain every password hash, session token and share
    # link in both applications. /media/data is exported over NFS with
    # no_root_squash, so root on any cluster node can still read them - this
    # keeps them away from everything else.
    mkdir -p "$DUMP_DIR"
    chmod 700 "$DUMP_DIR"

    local failed=0
    for entry in "${DATABASES[@]}"; do
        IFS='|' read -r name namespace selector user dbname <<< "$entry"

        # Still record a failure per database so the alerts fire, but skip the
        # doomed kubectl calls - retrying each one only buries the real cause
        # already logged above under pages of klog output.
        if [[ $api_ok -eq 0 ]]; then
            log_error "Skipping '$name' - Kubernetes API unreachable"
            record "$name" 0
            failed=$((failed + 1))
            continue
        fi

        dump_database "$name" "$namespace" "$selector" "$user" "$dbname" || failed=$((failed + 1))
    done

    # Each family's HELP/TYPE header is immediately followed by that family's
    # samples - see the note next to the *_LINES declarations.
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

    # Deliberately 0 - see the note at the top of this file.
    exit 0
}

main "$@"
