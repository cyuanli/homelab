# Homelab Infrastructure

_A large part of the files and basically all documentation is written by AI and reviewed by me. So are many of the commit messages (mine would never be this comprehensive)._

A complete homelab infrastructure combining K3s cluster for applications with VPS proxy for external access.

## Architecture Overview

### Infrastructure Stack
- **K3s Cluster**: Lightweight Kubernetes with HA control plane (3 nodes with embedded etcd)
- **VPS Proxy**: Nginx-based reverse proxy with load balancing across control planes
- **Tailscale**: Zero-config VPN mesh network connecting all nodes
- **Traefik**: K8s ingress controller with TLS termination
- **cert-manager**: Automatic SSL certificate management via Let's Encrypt
- **Storage**: Local persistent volumes with health monitoring

### Network Flow
```
Internet → VPS (Nginx) → Tailscale Tunnel → K3s Cluster (Traefik) → Applications
```

### Services
- **Media Stack**: Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin
- **Cloud Storage**: Nextcloud, Immich (photo management)
- **Home Automation**: Home Assistant with MariaDB
- **Games**: Minecraft servers with mc-router
- **Monitoring**: Prometheus, Grafana, Alertmanager
- **Other**: OwnTracks, BOINC, Whoami

## Quick Start

1. Clone the repository
2. Create node config: `cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local`
3. Edit config with your domain, email, and Tailscale auth key
4. Run: `./scripts/homelab.sh setup-all`
5. Verify: `./scripts/homelab.sh status`

For detailed setup instructions, see [Installation Guide](docs/INSTALLATION.md).

## Repository Structure

```
homelab/
├── cluster/                    # K3s manifests
│   ├── applications/          # Application deployments
│   │   ├── automation/       # Home Assistant, MariaDB
│   │   ├── boinc/            # BOINC distributed computing
│   │   ├── cloud/            # Nextcloud, Immich
│   │   ├── games/            # Minecraft servers
│   │   ├── location/         # OwnTracks
│   │   ├── media-stack/      # Jellyfin, Sonarr, Radarr, etc.
│   │   ├── monitoring/       # Prometheus, Grafana, Alertmanager
│   │   └── utilities/        # Whoami test service
│   ├── infrastructure/        # NFS storage, priority classes
│   └── manifests/            # Traefik, cert-manager
├── config/                    # Configuration
│   ├── borgmatic/            # Backup configuration
│   ├── service-configs/      # Auth, monitoring configs
│   ├── systemd/              # Timer/service units
│   └── templates/            # Node config templates
├── docs/                      # Documentation
├── nodes/                     # Per-node configs (gitignored secrets)
├── scripts/                   # Automation scripts
└── vps/                       # VPS reverse proxy setup
```

## Script Usage

```bash
./scripts/homelab.sh setup-all     # Complete setup (system + cluster + apps)
./scripts/homelab.sh setup-system  # System packages, Tailscale, firewall
./scripts/homelab.sh setup-cluster # K3s installation
./scripts/homelab.sh deploy        # Deploy all applications
./scripts/homelab.sh deploy media  # Deploy specific stack
./scripts/homelab.sh status        # Cluster health check
./scripts/homelab.sh logs <svc>    # View service logs
```

## Adding Nodes

```bash
./scripts/manage-nodes.sh add <hostname> --role server  # Control plane
./scripts/manage-nodes.sh add <hostname>                # Worker node

# On new node:
./scripts/homelab.sh setup-system
./scripts/homelab.sh setup-cluster
```

Use 3 or 5 control planes for HA (odd number for etcd quorum).

## VPS Proxy Setup

```bash
# On VPS
cd vps/
cp config/vps.env config/vps.env.local
# Edit: HOME_PC_NAMES="cyl-homelab cyl-optiplex9020 cyl-mitx"
sudo bash scripts/setup.sh
```

Configure DNS A records (*.your-domain.com → VPS public IP).

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - System design overview
- [Installation](docs/INSTALLATION.md) - Detailed setup guide
- [Operations](docs/OPERATIONS.md) - Day-to-day management
- [Configuration](docs/CONFIGURATION.md) - Config reference
- [Storage](docs/STORAGE.md) - SnapRAID/MergerFS setup
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues
- [Development](docs/DEVELOPMENT.md) - Adding new services
