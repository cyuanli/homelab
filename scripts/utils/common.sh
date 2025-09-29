#!/bin/bash

# Common utility functions for homelab setup scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==== $1 ====${NC}"
}

# Error handling
set_error_handling() {
    set -euo pipefail
    trap 'log_error "Script failed at line $LINENO"' ERR
}

# Load configuration
load_config() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local homelab_root="$(cd "$script_dir/.." && pwd)"
    local config_file="${1:-}"

    if [[ -z "$config_file" ]]; then
        local hostname=$(hostname)
        config_file="$homelab_root/nodes/$hostname/config.env.local"
    fi

    if [[ ! -f "$config_file" ]]; then
        log_error "Node configuration file not found: $config_file"
        log_error "Every node MUST have its own config file"
        exit 1
    fi

    log_info "Loading configuration from $config_file"
    # shellcheck source=/dev/null
    source "$config_file"

    # Export commonly used variables
    export HOMELAB_ROOT="$homelab_root"
    export CONFIG_FILE="$config_file"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check required variables are set
check_required_vars() {
    local missing_vars=()

    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi
}

# Wait for condition with timeout
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-300}"
    local interval="${3:-5}"
    local elapsed=0

    log_info "Waiting for condition: $condition"

    while ! eval "$condition"; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for condition: $condition"
            return 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    log_success "Condition met: $condition"
}

# Check if running as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
}

# Check if running as specific user
check_user() {
    local required_user="$1"
    if [[ "$(whoami)" != "$required_user" ]]; then
        log_error "This script must be run as user: $required_user"
        exit 1
    fi
}

# Create directory with proper ownership
create_directory() {
    local dir="$1"
    local owner="${2:-$HOMELAB_USER:$HOMELAB_USER}"

    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        sudo mkdir -p "$dir"
        sudo chown "$owner" "$dir"
    fi
}

# Apply Kubernetes manifest with substitution
apply_k8s_manifest() {
    local template_file="$1"
    local namespace="${2:-default}"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template file not found: $template_file"
        return 1
    fi

    log_info "Applying manifest: $template_file"

    # Substitute environment variables in template
    envsubst < "$template_file" | kubectl apply -f -
}

# Wait for deployment to be ready
wait_for_deployment() {
    local deployment="$1"
    local namespace="${2:-default}"

    log_info "Waiting for deployment $deployment in namespace $namespace"
    kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout=300s
}

# Wait for all pods in namespace to be ready
wait_for_namespace_ready() {
    local namespace="$1"

    log_info "Waiting for all pods in namespace $namespace to be ready"
    wait_for_condition "kubectl get pods -n $namespace --no-headers 2>/dev/null | grep -v Completed | awk '{print \$3}' | grep -v Running | wc -l | grep -q '^0$'" 300
}

# Check if K3s is running
check_k3s_running() {
    local service_name="k3s"
    if [[ "${NODE_ROLE:-}" == "agent" ]]; then
        service_name="k3s-agent"
    fi

    systemctl is-active --quiet "$service_name" && kubectl get nodes >/dev/null 2>&1
}

# Ensure service is enabled and started
ensure_service_enabled() {
    local service_name="$1"

    log_info "Enabling and starting service: $service_name"
    sudo systemctl enable "$service_name"
    sudo systemctl start "$service_name"

    if ! sudo systemctl is-active --quiet "$service_name"; then
        log_error "Failed to start service: $service_name"
        return 1
    fi
}

# Backup configuration files
backup_configs() {
    local backup_dir="$1"
    local source_dir="$2"

    log_info "Backing up configurations from $source_dir to $backup_dir"
    mkdir -p "$backup_dir"

    if [[ -d "$source_dir" ]]; then
        cp -r "$source_dir"/* "$backup_dir/"
        log_success "Backup completed"
    else
        log_warning "Source directory not found: $source_dir"
    fi
}

# Restore configuration files
restore_configs() {
    local backup_dir="$1"
    local target_dir="$2"

    log_info "Restoring configurations from $backup_dir to $target_dir"

    if [[ -d "$backup_dir" ]]; then
        mkdir -p "$target_dir"
        cp -r "$backup_dir"/* "$target_dir/"
        chown -R "$HOMELAB_USER:$HOMELAB_USER" "$target_dir"
        log_success "Restore completed"
    else
        log_warning "Backup directory not found: $backup_dir"
    fi
}

# Generate random password
generate_password() {
    local length="${1:-32}"
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# URL encode function
url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}