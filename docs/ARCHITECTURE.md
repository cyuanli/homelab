# Architecture Overview

## Network Flow

```
Internet → VPS (Nginx) → Tailscale VPN → K3s Cluster (Traefik) → Applications
```

## Components

### Infrastructure
- **K3s**: Lightweight Kubernetes with 3-node HA control plane (embedded etcd).
  7 nodes total: 3 servers (`cyl-homelab`, `cyl-mitx`, `cyl-optiplex9020`) and
  4 agents (`cyl-aspiree17`, `cyl-inspiron14`, `cyl-xps13`, `cyl-yoga213`).
- **Traefik**: Ingress controller with automatic HTTPS. Deployed from
  `cluster/manifests/traefik/` as a **DaemonSet in the `infrastructure`
  namespace** — not the K3s bundled Traefik in `kube-system`.
- **cert-manager**: Let's Encrypt certificate management (installed separately;
  this repo tracks only the ClusterIssuers).
- **VPS Proxy**: Nginx load balancing across control planes via Tailscale

### Storage
- **SnapRAID + MergerFS**: Unified `/media/data` pool with parity protection
- **NFS**: Exports storage to all cluster nodes
- **local-path**: K3s default for node-local volumes

### Monitoring
- **Prometheus**: Metrics collection
- **Grafana**: Dashboards
- **Alertmanager**: Discord notifications
- **Custom scripts**: Disk health, backup status → Prometheus metrics

## Namespaces

| Namespace | Services |
|-----------|----------|
| `infrastructure` | Traefik (DaemonSet), shared middlewares |
| `media` | Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent |
| `cloud` | Nextcloud, Immich (+ machine-learning, redis), PostgreSQL, Redis |
| `automation` | Home Assistant, MariaDB, Mosquitto, Zigbee2MQTT |
| `games` | Minecraft servers (Cobblestone, Sandstone, Apricorn), mc-router, backup CronJob |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), blackbox-exporter, alertmanager-discord |
| `location` | OwnTracks recorder + frontend, backup CronJob |
| `utilities` | Syncthing, Whoami |
| `cert-manager` | cert-manager controller, cainjector, webhook |

`cluster/manifests/namespaces/namespaces.yaml` creates `infrastructure`,
`media`, `cloud`, `utilities`, `monitoring` and `automation`. The `games`,
`location` and `cert-manager` namespaces are created by their own manifests or
by the installer that owns them.

## Storage Architecture

All of this lives on the single storage node `cyl-homelab` (192.168.1.94).

```
Physical: /mnt/data1..4 (SnapRAID data drives, ext4)   /srv/app-storage (OS SSD)
          /mnt/parity1  (SnapRAID parity, XFS)                  ↓
              ↓                                          bind → /exports/configs
MergerFS: /media/data (unified pool, ~6.8 TB)                  (fsid=2)
              ↓
   bind → /exports/media   (fsid=1)  → K8s PVs (bulk media, Nextcloud, Immich library)
   bind → /exports/games              → K8s PVs (Minecraft backups, via pseudo-root)
```

Split by workload: bulk, read-heavy data sits on the MergerFS HDD pool;
write-heavy caches (Immich thumbnails and encoded video, app configs) sit on the
OS SSD under `/srv/app-storage`.

## High Availability

- **Control Plane**: 3 server nodes with etcd quorum (tolerates 1 failure)
- **VPS Load Balancing**: Round-robin with health checks
- **Certificate Management**: cert-manager handles renewal automatically

## Single Points of Failure

- VPS proxy (external access)
- PostgreSQL databases (no replication)
- Storage node (NFS server)

Mitigated by: Borgmatic backups, SnapRAID parity, monitoring alerts
