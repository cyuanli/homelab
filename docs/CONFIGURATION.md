# Configuration Reference

## Configuration Files

| File | Purpose |
|------|---------|
| `nodes/<hostname>/config.env.local` | Node-specific settings (secrets, gitignored) |
| `nodes/<hostname>/labels.yaml` | Node labels/taints, applied with `kubectl apply -f` |
| `config/service-configs/monitoring.conf` | Storage monitoring drive map (gitignored; template alongside) |
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

### monitoring.conf

Drive map used by `scripts/monitor-storage.sh`. Copy
`config/service-configs/monitoring.conf.template` to `monitoring.conf` (the
`.conf` extension is gitignored) and set it to match **this host's** partitions:

```bash
# Data partitions (without /dev/ prefix) and the mount point each one carries.
# The two arrays are positional — index N of one must match index N of the other.
DATA_PARTITIONS=("sdf1" "sdb1" "sdc1" "sde1")
DATA_MOUNT_POINTS=("/mnt/data1" "/mnt/data2" "/mnt/data3" "/mnt/data4")

PARITY_PARTITIONS=("sdd1")
PARITY_MOUNT_POINTS=("/mnt/parity1")

# Physical drives for SMART checks (without /dev/ prefix)
DATA_DRIVES=("sdf" "sdb" "sdc" "sde")
PARITY_DRIVES=("sdd")

MERGERFS_MOUNT="/media/data"
```

> ⚠️ **`/dev/sdX` names are not stable across reboots.** They have already been
> reshuffled once on `cyl-homelab`. After any reboot or drive change, re-derive
> the mapping and update this file — a stale map means SMART checks run against
> the wrong disk. Current authoritative mapping:
> [`config/system-configs/DRIVE-MAPPING.md`](../config/system-configs/DRIVE-MAPPING.md).
>
> ```bash
> lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT   # partition → mount
> ls -l /dev/disk/by-id/ | grep -v part             # stable serial → /dev/sdX
> ```

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
