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

### Prerequisites
- Fresh Debian/Ubuntu machine for K3s cluster
- VPS with public IP for external access (optional)
- **Tailscale account** and auth key ([generate here](https://login.tailscale.com/admin/settings/keys))
- Domain name with DNS pointing to VPS (if using VPS proxy)

### First Server Node Setup

**Important:** This is for bootstrapping your FIRST server node. For adding additional nodes, see [Adding Nodes](#adding-nodes).

1. **Clone the repository**
   ```bash
   git clone <this-repo>
   cd homelab
   ```

2. **Create configuration for this node**
   ```bash
   # Create node-specific config directory
   mkdir -p nodes/$(hostname)

   # Copy template and edit with your values
   cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local
   nano nodes/$(hostname)/config.env.local
   ```

3. **Edit the configuration**

   Replace these placeholders in `nodes/$(hostname)/config.env.local`:
   ```bash
   DOMAIN="your-domain.com"                 # Your domain
   ACME_EMAIL="you@your-domain.com"        # For Let's Encrypt
   TAILSCALE_AUTHKEY="tskey-auth-..."      # From Tailscale admin

   # Leave these as-is for first server:
   NODE_ROLE=server
   CLUSTER_TOKEN=REPLACE_WITH_CLUSTER_TOKEN  # Auto-generated on install
   SERVER_URL=REPLACE_WITH_SERVER_URL        # Not needed for first server
   ```

4. **Run the automated setup**
   ```bash
   # This installs everything: system packages, K3s, applications
   ./scripts/homelab.sh setup-all

   # Or run steps individually:
   ./scripts/homelab.sh setup-system    # Install packages, Docker, Tailscale
   ./scripts/homelab.sh setup-cluster   # Install K3s
   ./scripts/homelab.sh deploy          # Deploy applications
   ```

5. **Verify installation**
   ```bash
   ./scripts/homelab.sh status
   # Should show: K3s running, all pods healthy
   ```

6. **Setup VPS proxy (optional)**
   ```bash
   # On VPS
   cd vps/
   cp config/vps.env config/vps.env.local
   # Edit with your settings
   sudo bash scripts/setup.sh
   ```

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

## Configuration

### Node Configuration (`nodes/<hostname>/config.env.local`)

Key configuration sections:

**Domain & Network**
```bash
DOMAIN="your-domain.com"
ACME_EMAIL="you@your-domain.com"
VPS_IP="100.x.x.x"  # Tailscale IP of VPS
```

**Storage Paths**
```bash
DATA_ROOT="/media/data"           # Main data directory
K8S_STORAGE_ROOT="/opt/k3s-storage"  # K8s persistent volumes
```

**Services**
```bash
NODE_ROLE="server"                # server or agent
ENABLE_TRAEFIK_DASHBOARD="true"
ENABLE_DISK_MONITORING="true"
```

**Monitoring**
All monitoring alerts are centralized through Prometheus and Alertmanager. Discord webhook is configured in:
```
cluster/applications/monitoring/alertmanager/alertmanager.yaml
```

### Service Authentication (`config/service-configs/`)
- `auth.conf`: HTTP Basic Auth credentials for admin interfaces
- `monitoring.conf`: Storage drive configuration for disk health monitoring

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
