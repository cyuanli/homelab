# Configuration Reference

## Configuration Files

| File | Purpose |
|------|---------|
| `nodes/<hostname>/config.env.local` | Node-specific settings (secrets, gitignored) |
| `nodes/<hostname>/labels.yaml` | Node labels/taints, applied with `kubectl apply -f` |
| `config/borgmatic/config.yaml` | Borgmatic backup config (deployed to `/etc/borgmatic/config.yaml`) |
| `config/system-configs/` | Reference copies of host configs (`fstab`, `snapraid.conf`, `exports`) |
| `ansible/inventory.yml` | Node inventory and group membership |
| `ansible/group_vars/all/vault.yml` | Ansible-vault encrypted values (K3s cluster token) |

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

# Container user/group + timezone for LinuxServer-style images
PUID="1000"
PGID="1000"
TIMEZONE="Europe/Zurich"

# Feature flags (read by scripts/)
ENABLE_LOCATION_SERVICES="true"   # gates OwnTracks in deploy-applications.sh
ENABLE_DISK_MONITORING="true"
ENABLE_BACKUP_MONITORING="true"
ENABLE_TRAEFIK_DASHBOARD="false"
```

See `config/templates/node-config.env.template` for the full key list.
`scripts/utils/common.sh:load_config()` loads
`nodes/$(hostname)/config.env.local` and fails hard if it is missing — every
node needs its own.

### For Additional Nodes

```bash
# Get from first server: sudo cat /var/lib/rancher/k3s/server/node-token
CLUSTER_TOKEN="K10..."

# First server's Tailscale IP
SERVER_URL="https://100.x.x.x:6443"
```

## Service Configs

### Storage monitoring

`scripts/monitor-storage.sh` has no config file. It reads the SnapRAID disks
from `/etc/snapraid.conf` and resolves devices at run time, because `/dev/sdX`
names change between boots. Current mapping:
[`config/system-configs/DRIVE-MAPPING.md`](../config/system-configs/DRIVE-MAPPING.md).

Alerting is not configured here — alerts are emitted as Prometheus metrics to
the node_exporter textfile collector and routed by Alertmanager (Discord via
`alertmanager-discord` in the `monitoring` namespace).

### HTTP Basic Auth

Admin interfaces are protected by **Traefik `basicAuth` middlewares**, not a
config file. Each is a `Middleware` CR plus a gitignored `secrets.yaml` holding
the htpasswd hash:

| Middleware | Namespace | Protects |
|------------|-----------|----------|
| `prometheus-auth` | `monitoring` | Prometheus, Alertmanager |
| `owntracks-auth` | `location` | OwnTracks recorder + frontend |
| `zigbee2mqtt-auth` | `automation` | Zigbee2MQTT |

Generate a hash with `htpasswd -nbm <user> <password>`.

## Kubernetes Secrets

Sensitive configs use `secrets.yaml` files (gitignored). Templates provided as `secrets.yaml.template`.

```bash
# Create secret from template
cp secrets.yaml.template secrets.yaml
# Edit with real values
kubectl apply -f secrets.yaml
```
