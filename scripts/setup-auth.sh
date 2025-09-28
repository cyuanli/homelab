#!/usr/bin/env bash
# Service Authentication Setup Script
# Generates HTTP Basic Auth credentials and K8s secrets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

# Load configuration
load_config

show_usage() {
    cat << EOF
Service Authentication Setup

Usage: $0 [service] [options]

Services:
  owntracks    - Setup Owntracks HTTP Basic Auth
  general      - Create generic HTTP Basic Auth

Options:
  --username   - Specify username (interactive if not provided)
  --password   - Specify password (interactive if not provided)
  --namespace  - K8s namespace (default: location for owntracks, utilities for general)

Examples:
  $0 owntracks
  $0 general --username admin --namespace media
  $0 owntracks --username user1 --password mypass

EOF
}

generate_htpasswd() {
    local username="$1"
    local password="$2"

    # Check if htpasswd is available
    if ! command_exists htpasswd; then
        log_info "htpasswd not found. Installing apache2-utils..."
        sudo apt-get update && sudo apt-get install -y apache2-utils
    fi

    # Generate htpasswd entry
    local htpasswd_entry
    htpasswd_entry=$(htpasswd -nb "$username" "$password")

    # Escape the $ characters for docker-compose/k8s
    local escaped_entry
    escaped_entry=$(echo "$htpasswd_entry" | sed 's/\$/\$\$/g')

    echo "$htpasswd_entry"
}

create_k8s_secret() {
    local service="$1"
    local namespace="$2"
    local username="$3"
    local password="$4"

    local secret_name="${service}-auth"

    log_info "Creating K8s secret: $secret_name in namespace: $namespace"

    # Ensure namespace exists
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

    # Delete existing secret if it exists
    kubectl delete secret "$secret_name" -n "$namespace" 2>/dev/null || true

    # Create new secret
    kubectl create secret generic "$secret_name" \
        --from-literal=username="$username" \
        --from-literal=password="$password" \
        --from-literal=htpasswd="$(generate_htpasswd "$username" "$password")" \
        -n "$namespace"

    log_success "Created K8s secret: $secret_name"
}

setup_owntracks_auth() {
    local username="$1"
    local password="$2"
    local namespace="${3:-location}"

    log_step "Setting up Owntracks HTTP Basic Authentication"

    # Generate htpasswd entry
    local htpasswd_entry
    htpasswd_entry=$(generate_htpasswd "$username" "$password")

    log_info "Generated authentication entry:"
    echo "$htpasswd_entry"

    # Create K8s secret
    create_k8s_secret "owntracks" "$namespace" "$username" "$password"

    cat << EOF

${GREEN}✅ Owntracks authentication setup complete!${NC}

Configuration details:
  Username: $username
  Password: [provided]
  Namespace: $namespace
  Secret: owntracks-auth

Configure your Owntracks mobile apps with:
  Mode: HTTP
  URL: https://owntracks.$DOMAIN/pub
  Username: $username
  Password: [the password you provided]

Web interface will be available at:
  URL: https://owntracks.$DOMAIN/
  Username: $username
  Password: [the password you provided]

To update the deployment to use this auth:
  kubectl rollout restart deployment/owntracks -n $namespace

EOF
}

setup_general_auth() {
    local service="$1"
    local username="$2"
    local password="$3"
    local namespace="$4"

    log_step "Setting up HTTP Basic Authentication for $service"

    # Generate htpasswd entry
    local htpasswd_entry
    htpasswd_entry=$(generate_htpasswd "$username" "$password")

    log_info "Generated authentication entry:"
    echo "$htpasswd_entry"

    # Create K8s secret
    create_k8s_secret "$service" "$namespace" "$username" "$password"

    cat << EOF

${GREEN}✅ Authentication setup complete for $service!${NC}

Configuration details:
  Service: $service
  Username: $username
  Password: [provided]
  Namespace: $namespace
  Secret: ${service}-auth

To use this in your deployment, reference the secret:
  env:
  - name: AUTH_USERNAME
    valueFrom:
      secretKeyRef:
        name: ${service}-auth
        key: username
  - name: AUTH_PASSWORD
    valueFrom:
      secretKeyRef:
        name: ${service}-auth
        key: password

EOF
}

main() {
    local service="${1:-}"
    local username=""
    local password=""
    local namespace=""

    # Parse arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --username)
                username="$2"
                shift 2
                ;;
            --password)
                password="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    case "$service" in
        "owntracks")
            # Interactive input if not provided
            if [[ -z "$username" ]]; then
                echo -n "Enter username for Owntracks: "
                read -r username
            fi

            if [[ -z "$password" ]]; then
                echo -n "Enter password for Owntracks: "
                read -rs password
                echo
            fi

            namespace="${namespace:-location}"
            setup_owntracks_auth "$username" "$password" "$namespace"
            ;;
        "general")
            if [[ -z "$username" ]]; then
                echo -n "Enter username: "
                read -r username
            fi

            if [[ -z "$password" ]]; then
                echo -n "Enter password: "
                read -rs password
                echo
            fi

            if [[ -z "$namespace" ]]; then
                echo -n "Enter namespace: "
                read -r namespace
            fi

            # Use namespace as service name if not otherwise specified
            local service_name="${namespace}"
            setup_general_auth "$service_name" "$username" "$password" "$namespace"
            ;;
        "")
            log_error "No service specified"
            show_usage
            exit 1
            ;;
        *)
            log_error "Unknown service: $service"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"