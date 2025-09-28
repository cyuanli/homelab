# Development Guide

This guide covers development practices, customization procedures, and extension methods for the homelab infrastructure.

## Development Environment Setup

### Prerequisites

**Development Tools**
```bash
# Install development dependencies
sudo apt update
sudo apt install -y git vim nano curl wget jq yq

# Install additional tools for K8s development
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Install yamllint for YAML validation
sudo apt install yamllint
```

**IDE/Editor Setup**
```bash
# For VS Code users
code --install-extension ms-kubernetes-tools.vscode-kubernetes-tools
code --install-extension redhat.vscode-yaml

# Configure YAML settings for Kubernetes
cat << EOF > .vscode/settings.json
{
    "yaml.schemas": {
        "https://raw.githubusercontent.com/instrumenta/kubernetes-json-schema/master/v1.18.0-standalone-strict/all.json": "*.yaml"
    },
    "yaml.customTags": [
        "!Base64",
        "!Cidr",
        "!Ref",
        "!Sub"
    ]
}
EOF
```

### Development Workflow

**Repository Setup**
```bash
# Fork or clone repository
git clone <repository-url>
cd homelab

# Create development branch
git checkout -b feature/new-service

# Copy configuration template
cp config/homelab.env.template config/homelab.env.dev
# Edit with development-specific values
```

**Testing Environment**
```bash
# Use development configuration
export HOMELAB_ENV=dev
source config/homelab.env.dev

# Deploy to test namespace
kubectl create namespace test
kubectl config set-context --current --namespace=test
```

## Script Development

### Script Architecture

The homelab uses a modular script architecture:

```
scripts/
├── utils/
│   └── common.sh           # Shared functions and utilities
├── homelab.sh             # Main orchestrator script
├── setup-system.sh        # System preparation
├── setup-cluster.sh       # K3s installation
├── deploy-applications.sh # Application deployment
├── monitor-storage.sh     # Storage monitoring
└── manage-nodes.sh        # Node management
```

### Common Functions (`scripts/utils/common.sh`)

**Essential Functions**
```bash
# Source common functions in your scripts
source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

# Logging functions
log_info "Information message"
log_warn "Warning message"
log_error "Error message"

# Configuration loading
load_config                    # Loads config/homelab.env

# Kubernetes operations
kubectl_apply "path/to/manifest"
wait_for_deployment "namespace" "deployment-name"
check_pod_ready "namespace" "app=label"

# Service management
is_service_running "service-name"
restart_service "service-name"
```

**Function Templates**
```bash
# Standard function template
function_name() {
    local param1="$1"
    local param2="${2:-default_value}"

    log_info "Starting function_name with param1=$param1"

    # Validate parameters
    if [[ -z "$param1" ]]; then
        log_error "param1 is required"
        return 1
    fi

    # Main logic here
    if command_that_might_fail; then
        log_info "Command succeeded"
    else
        log_error "Command failed"
        return 1
    fi

    log_info "function_name completed successfully"
}
```

### Script Development Guidelines

**Error Handling**
```bash
# Always use strict error handling
set -euo pipefail

# Handle errors gracefully
cleanup() {
    local exit_code=$?
    log_info "Cleaning up..."
    # Cleanup logic here
    exit $exit_code
}
trap cleanup EXIT

# Check command success
if ! command_that_might_fail; then
    log_error "Command failed, exiting"
    exit 1
fi
```

**Parameter Validation**
```bash
# Validate required parameters
validate_parameters() {
    local required_vars=("DOMAIN" "HOMELAB_USER" "DATA_ROOT")

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable $var is not set"
            return 1
        fi
    done
}
```

**Idempotency**
```bash
# Make operations idempotent
install_package() {
    local package="$1"

    if dpkg -l | grep -q "^ii  $package "; then
        log_info "$package is already installed"
        return 0
    fi

    log_info "Installing $package"
    sudo apt update
    sudo apt install -y "$package"
}
```

## Adding New Services

### Service Development Process

**1. Plan Service Integration**
```bash
# Consider these questions:
# - What namespace should it run in?
# - What persistent storage does it need?
# - What external access is required?
# - What dependencies does it have?
# - How does it integrate with existing services?
```

**2. Create Kubernetes Manifests**
```bash
# Create service directory
mkdir -p cluster/applications/category/new-service

# Create base manifests
cd cluster/applications/category/new-service
```

**3. Deployment Manifest Template**
```yaml
# new-service.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: new-service
  namespace: category
  labels:
    app: new-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: new-service
  template:
    metadata:
      labels:
        app: new-service
    spec:
      containers:
      - name: new-service
        image: new-service:${NEW_SERVICE_VERSION}
        ports:
        - containerPort: 8080
        env:
        - name: PUID
          value: "${PUID}"
        - name: PGID
          value: "${PGID}"
        - name: TZ
          value: "${TIMEZONE}"
        volumeMounts:
        - name: config
          mountPath: /config
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        hostPath:
          path: ${K8S_STORAGE_ROOT}/new-service-config
          type: DirectoryOrCreate
      - name: data
        hostPath:
          path: ${DATA_ROOT}/new-service
          type: DirectoryOrCreate
```

**4. Service Manifest**
```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: new-service
  namespace: category
  labels:
    app: new-service
spec:
  selector:
    app: new-service
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  type: ClusterIP
```

**5. Ingress Manifest**
```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-service
  namespace: category
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    traefik.ingress.kubernetes.io/router.middlewares: default-auth@kubernetescrd
spec:
  rules:
  - host: new-service.${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: new-service
            port:
              number: 8080
  tls:
  - hosts:
    - new-service.${DOMAIN}
    secretName: new-service-tls
```

**6. Kustomization Configuration**
```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - new-service.yaml
  - service.yaml
  - ingress.yaml

images:
  - name: new-service
    newTag: latest

configMapGenerator:
  - name: new-service-config
    literals:
      - SERVICE_URL=https://new-service.${DOMAIN}
```

### Integration with Deployment Scripts

**Add to Configuration**
```bash
# In config/homelab.env.template
NEW_SERVICE_VERSION="latest"
ENABLE_NEW_SERVICE="true"
```

**Add to Deployment Script**
```bash
# In scripts/deploy-applications.sh
deploy_new_service() {
    if [[ "${ENABLE_NEW_SERVICE:-false}" == "true" ]]; then
        log_info "Deploying new service..."

        # Prepare directories
        ensure_directory "${K8S_STORAGE_ROOT}/new-service-config"
        ensure_directory "${DATA_ROOT}/new-service"

        # Apply manifests
        kubectl_apply "cluster/applications/category/new-service"

        # Wait for deployment
        wait_for_deployment "category" "new-service"

        log_info "New service deployed successfully"
    else
        log_info "New service disabled, skipping"
    fi
}

# Add to main deployment function
deploy_applications() {
    # ... existing deployments ...
    deploy_new_service
}
```

**Add to Main Orchestrator**
```bash
# In scripts/homelab.sh
case "$command" in
    # ... existing cases ...
    "new-service")
        case "${2:-deploy}" in
            "deploy")
                deploy_new_service
                ;;
            "restart")
                kubectl rollout restart deployment/new-service -n category
                ;;
            "logs")
                kubectl logs -n category deployment/new-service -f
                ;;
            *)
                echo "Usage: $0 new-service [deploy|restart|logs]"
                exit 1
                ;;
        esac
        ;;
esac
```

## Testing and Validation

### Unit Testing Scripts

**Test Framework Setup**
```bash
# Create test directory
mkdir -p tests/

# Simple test framework
cat << 'EOF' > tests/test_common.sh
#!/bin/bash
source scripts/utils/common.sh

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

# Test assertion functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "PASS: $message"
    else
        echo "FAIL: $message (expected: $expected, actual: $actual)"
    fi
}

assert_true() {
    local condition="$1"
    local message="${2:-}"

    if $condition; then
        assert_equals "true" "true" "$message"
    else
        assert_equals "true" "false" "$message"
    fi
}

# Test results
show_results() {
    echo ""
    echo "Tests run: $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $((TESTS_RUN - TESTS_PASSED))"

    if [[ $TESTS_PASSED -eq $TESTS_RUN ]]; then
        echo "All tests passed!"
        exit 0
    else
        echo "Some tests failed!"
        exit 1
    fi
}
EOF

chmod +x tests/test_common.sh
```

**Example Test**
```bash
# tests/test_configuration.sh
#!/bin/bash
source tests/test_common.sh

# Test configuration loading
test_config_loading() {
    export HOMELAB_ENV=test
    echo "DOMAIN=test.local" > config/homelab.env.test

    load_config

    assert_equals "test.local" "$DOMAIN" "Domain should be loaded from test config"

    rm -f config/homelab.env.test
}

# Run tests
test_config_loading
show_results
```

### Integration Testing

**Service Deployment Test**
```bash
#!/bin/bash
# tests/test_deployment.sh

# Deploy service to test namespace
kubectl create namespace test-deploy || true
export KUBERNETES_NAMESPACE=test-deploy

# Test deployment
deploy_new_service

# Verify deployment
assert_true "kubectl get deployment new-service -n test-deploy" "Deployment should exist"
assert_true "kubectl wait --for=condition=ready pod -l app=new-service -n test-deploy --timeout=60s" "Pod should be ready"

# Test service accessibility
kubectl port-forward -n test-deploy deployment/new-service 8080:8080 &
PORTFORWARD_PID=$!
sleep 5

assert_true "curl -s http://localhost:8080" "Service should be accessible"

# Cleanup
kill $PORTFORWARD_PID
kubectl delete namespace test-deploy
```

### Validation Scripts

**Configuration Validation**
```bash
# scripts/validate-config.sh
#!/bin/bash
source scripts/utils/common.sh

validate_homelab_config() {
    load_config

    local required_vars=(
        "DOMAIN"
        "HOMELAB_USER"
        "HOMELAB_UID"
        "HOMELAB_GID"
        "DATA_ROOT"
        "K8S_STORAGE_ROOT"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable $var is not set"
            return 1
        fi
    done

    # Validate paths exist
    if [[ ! -d "$DATA_ROOT" ]]; then
        log_error "DATA_ROOT directory does not exist: $DATA_ROOT"
        return 1
    fi

    # Validate user exists
    if ! id "$HOMELAB_USER" >/dev/null 2>&1; then
        log_error "User does not exist: $HOMELAB_USER"
        return 1
    fi

    log_info "Configuration validation passed"
}

validate_homelab_config
```

**Kubernetes Manifest Validation**
```bash
# scripts/validate-manifests.sh
#!/bin/bash

# Validate YAML syntax
find cluster/ -name "*.yaml" -exec yamllint {} \;

# Validate Kubernetes resources
find cluster/applications -name kustomization.yaml -execdir kubectl apply --dry-run=client -k . \;
```

## Debugging and Development Tools

### Development Helpers

**Debug Mode Script**
```bash
#!/bin/bash
# scripts/debug.sh

export DEBUG=true
export VERBOSE=true

# Enable detailed logging
set -x

# Source configuration
source config/homelab.env

# Interactive debugging session
echo "Debug mode enabled"
echo "Configuration loaded from: config/homelab.env"
echo "Cluster context: $(kubectl config current-context)"
echo "Available commands:"
echo "  kubectl get pods -A"
echo "  kubectl logs -n <namespace> deployment/<service>"
echo "  ./scripts/homelab.sh status"

bash
```

**Log Analysis Tools**
```bash
# scripts/analyze-logs.sh
#!/bin/bash

# Collect all relevant logs
kubectl logs -n kube-system deployment/traefik --tail=100 > debug-traefik.log
kubectl logs -n media deployment/jellyfin --tail=100 > debug-jellyfin.log
journalctl -u k3s --tail=100 > debug-k3s.log

# Analyze for common issues
grep -i error debug-*.log
grep -i fail debug-*.log
grep -i timeout debug-*.log

echo "Logs collected in debug-*.log files"
```

### Performance Testing

**Load Testing Script**
```bash
#!/bin/bash
# tests/load-test.sh

# Test service performance
test_service_load() {
    local service_url="$1"
    local concurrent_users="${2:-10}"
    local duration="${3:-60}"

    echo "Load testing $service_url with $concurrent_users users for ${duration}s"

    # Use curl for simple load testing
    for i in $(seq 1 $concurrent_users); do
        (
            end_time=$((SECONDS + duration))
            while [[ $SECONDS -lt $end_time ]]; do
                curl -s "$service_url" > /dev/null
                sleep 1
            done
        ) &
    done

    wait
    echo "Load test completed"
}

# Test all services
test_service_load "https://jellyfin.$DOMAIN" 5 30
test_service_load "https://nextcloud.$DOMAIN" 3 30
```

## Documentation Development

### Documentation Standards

**Markdown Guidelines**
- Use clear, descriptive headings
- Include code examples for all procedures
- Add troubleshooting sections for complex topics
- Use consistent formatting and terminology

**Code Documentation**
```bash
# Function documentation template
#
# Description: Brief description of what the function does
# Parameters:
#   $1: First parameter description
#   $2: Second parameter description (optional, default: value)
# Returns:
#   0: Success
#   1: Error condition 1
#   2: Error condition 2
# Example:
#   function_name "param1" "param2"
#
function_name() {
    # Implementation
}
```

### Auto-Generated Documentation

**Script Documentation Generator**
```bash
#!/bin/bash
# scripts/generate-docs.sh

# Generate function documentation from scripts
generate_function_docs() {
    local script_file="$1"

    echo "## Functions in $(basename $script_file)"
    echo ""

    # Extract function definitions and comments
    awk '/^#.*Description:/ {
        desc = substr($0, 3)
        getline
        while (/^#/) {
            desc = desc "\n" substr($0, 3)
            getline
        }
        if (/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/) {
            func_name = substr($0, 1, index($0, "(")-1)
            print "### " func_name
            print ""
            print desc
            print ""
        }
    }' "$script_file"
}

# Generate documentation for all scripts
for script in scripts/*.sh; do
    generate_function_docs "$script"
done > docs/SCRIPT_REFERENCE.md
```

## Contribution Guidelines

### Development Process

**1. Planning**
- Create GitHub issue describing the feature/fix
- Discuss implementation approach
- Plan testing strategy

**2. Implementation**
- Create feature branch from main
- Follow coding standards
- Write tests for new functionality
- Update documentation

**3. Testing**
- Run unit tests
- Test on clean environment
- Validate with existing infrastructure
- Performance testing if applicable

**4. Review**
- Submit pull request
- Address review feedback
- Ensure CI/CD passes
- Update changelog

### Code Standards

**Shell Script Standards**
```bash
#!/bin/bash
# File header with description and usage

# Strict error handling
set -euo pipefail

# Global variables in UPPERCASE
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Functions in lowercase with underscores
function_name() {
    local local_var="$1"
    # Implementation
}

# Main execution
main() {
    # Script logic
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

**Kubernetes Manifest Standards**
- Use consistent labeling strategy
- Include resource limits
- Follow namespace conventions
- Use environment variable substitution
- Document all custom annotations

### Release Process

**Version Tagging**
```bash
# Tag releases
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# Update version in configuration
echo "HOMELAB_VERSION=v1.0.0" >> config/homelab.env.template
```

**Changelog Maintenance**
```bash
# Keep CHANGELOG.md updated with:
# - New features
# - Bug fixes
# - Breaking changes
# - Migration instructions
```

This development guide provides the foundation for extending and customizing the homelab infrastructure while maintaining code quality and operational reliability.