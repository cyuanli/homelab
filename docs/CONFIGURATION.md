# Configuration Reference

## Configuration Files

| File | Purpose |
|------|---------|
| `nodes/<hostname>/config.env.local` | Node-specific settings (secrets, gitignored) |
| `config/service-configs/auth.conf` | HTTP Basic Auth credentials |
| `config/service-configs/monitoring.conf` | Storage monitoring settings |

## Node Configuration

Create from template: `cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local`

### Required Settings

```bash
DOMAIN="your-domain.com"
ACME_EMAIL="you@your-domain.com"
TAILSCALE_AUTHKEY="tskey-auth-..."

# User for file permissions
HOMELAB_USER="username"
HOMELAB_UID="1000"
HOMELAB_GID="1000"

# Storage paths
DATA_ROOT="/media/data"
K8S_STORAGE_ROOT="/opt/k3s-storage"

# Node role
NODE_ROLE="server"  # or "agent"
```

### For Additional Nodes

```bash
# Get from first server: sudo cat /var/lib/rancher/k3s/server/node-token
CLUSTER_TOKEN="K10..."

# First server's Tailscale IP
SERVER_URL="https://100.x.x.x:6443"
```

## Service Configs

### auth.conf
HTTP Basic Auth for admin interfaces (Traefik dashboard, etc.):
```bash
AUTH_USER="admin"
AUTH_PASSWORD="your-password"
```
Generate htpasswd: `htpasswd -nb admin yourpassword`

### monitoring.conf
Storage health monitoring:
```bash
WEBHOOK_URL="https://discord.com/api/webhooks/..."
MONITOR_DRIVES="/mnt/data1 /mnt/data2 /mnt/parity1"
```

## Kubernetes Secrets

Sensitive configs use `secrets.yaml` files (gitignored). Templates provided as `secrets.yaml.template`.

```bash
# Create secret from template
cp secrets.yaml.template secrets.yaml
# Edit with real values
kubectl apply -f secrets.yaml
```
