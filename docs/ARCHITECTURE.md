# Architecture Overview

## Network Flow

```
Internet → VPS (Nginx) → Tailscale VPN → K3s Cluster (Traefik) → Applications
```

## Components

### Infrastructure
- **K3s**: Lightweight Kubernetes with 3-node HA control plane (embedded etcd)
- **Traefik**: Ingress controller with automatic HTTPS
- **cert-manager**: Let's Encrypt certificate management
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
| `media` | Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent |
| `cloud` | Nextcloud, Immich, PostgreSQL, Redis |
| `automation` | Home Assistant, MariaDB |
| `games` | Minecraft servers, mc-router |
| `monitoring` | Prometheus, Grafana, Alertmanager |
| `boinc` | BOINC distributed computing |
| `location` | OwnTracks |
| `utilities` | Whoami |

## Storage Architecture

```
Physical: /mnt/data1..4 (SnapRAID data drives)
         /mnt/parity1  (SnapRAID parity)
              ↓
MergerFS: /media/data (unified pool)
              ↓
NFS: /exports/media → K8s PVs
```

## High Availability

- **Control Plane**: 3 server nodes with etcd quorum (tolerates 1 failure)
- **VPS Load Balancing**: Round-robin with health checks
- **Certificate Management**: cert-manager handles renewal automatically

## Single Points of Failure

- VPS proxy (external access)
- PostgreSQL databases (no replication)
- Storage node (NFS server)

Mitigated by: Borgmatic backups, SnapRAID parity, monitoring alerts
