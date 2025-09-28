# Configuration Reference

This document provides a comprehensive reference for all configuration options in the homelab infrastructure.

## Configuration Hierarchy

The homelab uses a layered configuration system:

1. **Global Configuration**: `config/homelab.env` - System-wide settings
2. **Service Configurations**: `config/service-configs/` - Service-specific settings
3. **Node Configurations**: `nodes/<hostname>/` - Node-specific settings
4. **Application Configurations**: `cluster/applications/` - Kubernetes manifests

## Global Configuration (`config/homelab.env`)

### Basic Configuration

**Domain and Networking**
```bash
# Primary domain for services
DOMAIN="your-domain.com"

# Email for Let's Encrypt certificate registration
ACME_EMAIL="admin@your-domain.com"

# Whether to use Let's Encrypt staging (for testing)
# Set to "false" for production certificates
LETSENCRYPT_STAGING="false"
```

**User Configuration**
```bash
# Linux username for file ownership
HOMELAB_USER="username"

# User ID (get with: id -u username)
HOMELAB_UID="1000"

# Group ID (get with: id -g username)
HOMELAB_GID="1000"

# Used by applications for file permissions
PUID="${HOMELAB_UID}"
PGID="${HOMELAB_GID}"

# System timezone
TIMEZONE="Etc/UTC"
```

### Tailscale Configuration

```bash
# Tailscale authentication key from admin console
# Generate at: https://login.tailscale.com/admin/settings/keys
TAILSCALE_AUTHKEY="tskey-auth-xxxxxxxxxxxxxxxx"

# VPS Tailscale IP (if using VPS proxy)
VPS_HOSTNAME="your-vps-hostname"
VPS_IP="100.xxx.xxx.xxx"
```

### Storage Configuration

**Primary Storage Paths**
```bash
# Main data directory (where media/downloads live)
DATA_ROOT="/media/data"

# Media subdirectories
MEDIA_MOVIES="${DATA_ROOT}/media/movies"
MEDIA_TV="${DATA_ROOT}/media/tv"
MEDIA_MUSIC="${DATA_ROOT}/media/music"
DOWNLOADS_DIR="${DATA_ROOT}/downloads"

# Kubernetes persistent volume storage
K8S_STORAGE_ROOT="/opt/k3s-storage"
```

**Storage Monitoring**
```bash
# Enable disk monitoring
ENABLE_DISK_MONITORING="true"

# Monitoring check interval in minutes
DISK_MONITOR_INTERVAL="5"

# Discord webhook for storage alerts
DISK_MONITOR_WEBHOOK="${DISCORD_WEBHOOK_URL}"
```

### K3s Configuration

**Cluster Settings**
```bash
# K3s version to install
K3S_VERSION="v1.28.8+k3s1"

# kubectl version (should match K3s version)
KUBECTL_VERSION="v1.28.8"

# Node role: "server" or "agent"
NODE_ROLE="server"

# Cluster token (auto-generated for first server)
CLUSTER_TOKEN=""

# Server URL (for agent nodes joining cluster)
SERVER_URL=""
```

### Service Configuration

**Container Versions**
```bash
# Infrastructure versions
TRAEFIK_VERSION="v3.0"

# Application versions
NEXTCLOUD_VERSION="latest"
JELLYFIN_VERSION="latest"
QBITTORRENT_VERSION="latest"
PROWLARR_VERSION="latest"
SONARR_VERSION="latest"
RADARR_VERSION="latest"
```

**Feature Flags**
```bash
# Enable Traefik dashboard
ENABLE_TRAEFIK_DASHBOARD="true"

# Enable OwnTracks location services
ENABLE_LOCATION_SERVICES="false"

# Enable storage monitoring
ENABLE_DISK_MONITORING="true"

# Enable backup monitoring
ENABLE_BACKUP_MONITORING="true"
```

### Monitoring & Notifications

**Discord Integration**
```bash
# Discord webhook URL for notifications
# Create webhook in Discord server settings
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/xxx/xxx"

# Use same webhook for different services
BORGMATIC_WEBHOOK_URL="${DISCORD_WEBHOOK_URL}"
```

### Security Configuration

**Firewall Settings**
```bash
# Enable UFW firewall configuration
ENABLE_UFW="true"

# Allow SSH from local network
ALLOW_SSH_FROM_LAN="true"

# Local network CIDR for SSH access
LAN_CIDR="192.168.0.0/16"
```

**Backup Configuration**
```bash
# Backup retention in days
BACKUP_RETENTION_DAYS="30"
```

## Service-Specific Configurations

### Authentication (`config/service-configs/auth.conf`)

Contains HTTP Basic Auth credentials for admin interfaces:

```bash
# Generated username and password for admin services
AUTH_USER="admin"
AUTH_PASSWORD="randomly-generated-password"

# Base64 encoded for Kubernetes secrets
AUTH_BASIC="YWRtaW46cGFzc3dvcmQ="
```

**Usage**: Used by Traefik dashboard, monitoring interfaces, etc.

**Generation**: Created by `./scripts/homelab.sh setup-auth`

### Monitoring (`config/service-configs/monitoring.conf`)

Storage monitoring configuration:

```bash
# Discord webhook for storage alerts
WEBHOOK_URL="https://discord.com/api/webhooks/xxx/xxx"

# Drives to monitor (space-separated list)
MONITOR_DRIVES="/mnt/data1 /mnt/data2 /mnt/parity1"

# Whether monitoring is enabled
MONITORING_ENABLED="true"
```

**Usage**: Used by storage monitoring scripts

## Node-Specific Configuration

### Node Configuration (`nodes/<hostname>/config.env`)

Each node can have specific settings:

```bash
# Node role in cluster
NODE_ROLE="server"  # or "agent"

# Cluster authentication token
CLUSTER_TOKEN="random-cluster-token"

# Server URL for agent nodes
SERVER_URL="https://100.xxx.xxx.xxx:6443"

# Node-specific Tailscale key (optional)
TAILSCALE_AUTHKEY="tskey-auth-xxxxxxxx"
```

**Creation**: Generated by `./scripts/manage-nodes.sh add <node-name>`

## Application Configurations

### Kustomize Overlays

Applications use Kustomize for configuration management:

**Structure**:
```
cluster/applications/<service>/
├── kustomization.yaml    # Kustomize configuration
├── <service>.yaml        # Main deployment
├── service.yaml          # Kubernetes service
├── ingress.yaml          # Traefik ingress
└── secrets.yaml          # Sensitive configuration
```

**Example Kustomization** (`cluster/applications/media-stack/jellyfin/kustomization.yaml`):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - jellyfin.yaml
  - service.yaml
  - ../ingress.yaml

images:
  - name: jellyfin/jellyfin
    newTag: latest

configMapGenerator:
  - name: jellyfin-config
    literals:
      - JELLYFIN_PublishedServerUrl=https://jellyfin.your-domain.com
```

### Environment Variable Substitution

Many configurations support environment variable substitution from `homelab.env`:

**In Kubernetes manifests**:
```yaml
spec:
  containers:
  - name: jellyfin
    env:
    - name: PUID
      value: "${PUID}"
    - name: PGID
      value: "${PGID}"
    volumeMounts:
    - name: media
      mountPath: /media
  volumes:
  - name: media
    hostPath:
      path: "${DATA_ROOT}/media"
```

**Processing**: Done by deployment scripts using `envsubst`

## Configuration Templates

### Creating New Service Configurations

**1. Add to Global Config**
```bash
# In config/homelab.env
NEW_SERVICE_VERSION="latest"
NEW_SERVICE_PORT="8080"
ENABLE_NEW_SERVICE="true"
```

**2. Create Kubernetes Manifests**
```bash
mkdir -p cluster/applications/category/new-service
cd cluster/applications/category/new-service

# Create deployment, service, ingress files
# Use existing services as templates
```

**3. Add to Deployment Scripts**
```bash
# In scripts/deploy-applications.sh
deploy_new_service() {
    log_info "Deploying new service..."
    kubectl_apply "cluster/applications/category/new-service"
    wait_for_deployment "namespace" "new-service"
}
```

### Configuration Validation

**Built-in Validation**
```bash
# Check configuration syntax
./scripts/homelab.sh config

# Validate before deployment
./scripts/homelab.sh deploy --dry-run
```

**Manual Validation**
```bash
# Check required variables are set
source config/homelab.env
echo "Domain: $DOMAIN"
echo "User: $HOMELAB_USER"
echo "Data Root: $DATA_ROOT"

# Check file permissions
ls -la "$DATA_ROOT"
ls -la "$K8S_STORAGE_ROOT"
```

## Configuration Security

### Secrets Management

**Sensitive Information**
- Never commit real secrets to git
- Use `.env.template` files for examples
- Store real configs in `.env.local` or similar

**Kubernetes Secrets**
```bash
# Create secret from config
kubectl create secret generic app-config \
  --from-env-file=config/service-configs/app.conf

# Update existing secret
kubectl delete secret app-config
kubectl create secret generic app-config \
  --from-env-file=config/service-configs/app.conf
```

### Configuration Backup

**Backup Strategy**
```bash
# Backup configuration files
tar -czf homelab-config-backup.tar.gz \
  config/ \
  nodes/ \
  cluster/applications/*/secrets.yaml

# Exclude from regular backups (contains secrets)
echo "homelab-config-backup.tar.gz" >> .gitignore
```

**Restoration**
```bash
# Restore configuration
tar -xzf homelab-config-backup.tar.gz

# Redeploy with restored config
./scripts/homelab.sh deploy
```

## Environment-Specific Configurations

### Development Environment

```bash
# In config/homelab.env
DOMAIN="homelab.local"
LETSENCRYPT_STAGING="true"
ENABLE_TRAEFIK_DASHBOARD="true"
K3S_VERSION="latest"
```

### Production Environment

```bash
# In config/homelab.env
DOMAIN="your-production-domain.com"
LETSENCRYPT_STAGING="false"
ENABLE_TRAEFIK_DASHBOARD="false"
K3S_VERSION="v1.28.8+k3s1"  # Pinned version
```

### Testing Environment

```bash
# In config/homelab.env
DOMAIN="test.your-domain.com"
LETSENCRYPT_STAGING="true"
ENABLE_DISK_MONITORING="false"
ENABLE_BACKUP_MONITORING="false"
```

## Configuration Troubleshooting

### Common Issues

**Missing Environment Variables**
```bash
# Check if variables are loaded
source config/homelab.env
env | grep HOMELAB

# Check for typos in variable names
grep -n "DOMAIN" config/homelab.env
```

**Permission Issues**
```bash
# Fix config file permissions
chmod 600 config/homelab.env
chmod 600 config/service-configs/*

# Fix ownership
chown $USER:$USER config/homelab.env
```

**Template Substitution Failures**
```bash
# Test template substitution
source config/homelab.env
echo "${DOMAIN}" | envsubst

# Check for undefined variables
envsubst < template.yaml > /dev/null
```

### Configuration Validation Commands

```bash
# Validate YAML syntax
yamllint cluster/applications/**/*.yaml

# Check Kubernetes resource definitions
kubectl apply --dry-run=client -k cluster/applications/media-stack/

# Test configuration loading
./scripts/utils/common.sh load_config
```

This configuration system provides flexibility while maintaining security and consistency across the homelab infrastructure.