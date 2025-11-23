#!/usr/bin/env bash
# Prometheus metrics export helper functions
# Source this file in monitoring scripts to export metrics

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

# Ensure the textfile directory exists
ensure_textfile_dir() {
    if [ ! -d "$TEXTFILE_DIR" ]; then
        mkdir -p "$TEXTFILE_DIR" 2>/dev/null || {
            log_warn "Cannot create textfile directory: $TEXTFILE_DIR"
            return 1
        }
    fi
    return 0
}

# Write a metric to a textfile atomically
# Usage: write_metric <filename> <content>
write_metric_file() {
    local filename="$1"
    local content="$2"
    local filepath="$TEXTFILE_DIR/${filename}"
    local tmpfile="${filepath}.tmp.$$"

    ensure_textfile_dir || return 1

    # Write to temp file first
    cat > "$tmpfile" <<EOF
$content
EOF

    # Atomic move
    if mv "$tmpfile" "$filepath" 2>/dev/null; then
        chmod 644 "$filepath" 2>/dev/null || true
        return 0
    else
        rm -f "$tmpfile" 2>/dev/null || true
        log_warn "Failed to write metric file: $filepath"
        return 1
    fi
}

# Export a gauge metric header (HELP and TYPE lines)
# Usage: export_gauge_header <metric_name> <help_text>
export_gauge_header() {
    local metric_name="$1"
    local help_text="${2:-Metric exported by monitoring script}"

    cat <<EOF
# HELP ${metric_name} ${help_text}
# TYPE ${metric_name} gauge
EOF
}

# Export a gauge metric data line (without HELP/TYPE)
# Usage: export_gauge_line <metric_name> <value> <labels>
export_gauge_line() {
    local metric_name="$1"
    local value="$2"
    local labels="${3:-}"

    local label_str=""
    if [ -n "$labels" ]; then
        label_str="{$labels}"
    fi

    echo "${metric_name}${label_str} ${value}"
}

# Export a gauge metric (header + single data line)
# Usage: export_gauge <metric_name> <value> <labels> <help_text>
export_gauge() {
    local metric_name="$1"
    local value="$2"
    local labels="${3:-}"
    local help_text="${4:-Metric exported by monitoring script}"

    export_gauge_header "$metric_name" "$help_text"
    export_gauge_line "$metric_name" "$value" "$labels"
}

# Export a counter metric
# Usage: export_counter <metric_name> <value> <labels> <help_text>
export_counter() {
    local metric_name="$1"
    local value="$2"
    local labels="${3:-}"
    local help_text="${4:-Counter metric exported by monitoring script}"

    local label_str=""
    if [ -n "$labels" ]; then
        label_str="{$labels}"
    fi

    cat <<EOF
# HELP ${metric_name} ${help_text}
# TYPE ${metric_name} counter
${metric_name}${label_str} ${value}
EOF
}

# Get current Unix timestamp
get_timestamp() {
    date +%s
}

# Convert seconds to milliseconds
seconds_to_ms() {
    echo "$1 * 1000" | bc
}
