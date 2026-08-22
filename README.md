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
- **Media Stack** (`media`): Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin
- **Cloud Storage** (`cloud`): Nextcloud, Immich (photo management), PostgreSQL, Redis
- **Home Automation** (`automation`): Home Assistant, MariaDB, Mosquitto (MQTT), Zigbee2MQTT
- **Games** (`games`): Minecraft servers (Cobblestone, Sandstone, Apricorn) with mc-router
- **Monitoring** (`monitoring`): Prometheus, Grafana, Alertmanager, blackbox-exporter, alertmanager-discord
- **Utilities** (`utilities`): Syncthing, Whoami
- **Location** (`location`): OwnTracks (recorder + frontend)

BOINC manifests live in `cluster/applications/boinc/` but are **not currently
deployed** (no `boinc` namespace in the cluster). See its
[README](cluster/applications/boinc/README.md).

## Quick Start

1. Clone the repository
2. Create node config: `cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local`
3. Edit config with your domain, email, and Tailscale auth key
4. Run Ansible playbooks for system setup and K3s install (see [Installation Guide](docs/INSTALLATION.md))
5. Deploy apps: `./scripts/homelab.sh deploy`
6. Verify: `./scripts/homelab.sh status`

For detailed setup instructions, see [Installation Guide](docs/INSTALLATION.md).

## Repository Structure

```
homelab/
├── cluster/                    # K3s manifests
│   ├── applications/          # Application deployments
│   │   ├── automation/       # Home Assistant, MariaDB, Mosquitto, Zigbee2MQTT
│   │   ├── boinc/            # BOINC distributed computing (not deployed)
│   │   ├── cloud/            # Nextcloud, Immich
│   │   ├── games/            # Minecraft worlds, mc-router, backup CronJob
│   │   ├── location/         # OwnTracks
│   │   ├── media-stack/      # Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent
│   │   ├── monitoring/       # kube-prometheus-stack values, alert rules, blackbox
│   │   └── utilities/        # Syncthing, Whoami
│   ├── infrastructure/        # NFS StorageClass, priority classes
│   └── manifests/            # Namespaces, Traefik, cert-manager issuers, storage
├── config/                    # Configuration
│   ├── borgmatic/            # Backup config + systemd units
│   ├── service-configs/      # Storage monitoring config (gitignored + template)
│   ├── system-configs/       # Backed-up host configs (fstab, snapraid, exports)
│   ├── systemd/              # Timer/service units
│   └── templates/            # Node config template
├── ansible/                   # Ansible playbooks for host setup
├── docs/                      # Documentation
├── nodes/                     # Per-node configs + labels (secrets gitignored)
├── scripts/                   # Automation scripts
└── vps/                       # VPS reverse proxy setup
```

Note: `cluster/manifests/` holds cluster bootstrap resources applied with plain
`kubectl apply`; `cluster/applications/` holds per-app Kustomize overlays and
Helm values.

## Script Usage

```bash
# Ansible playbooks (system setup, K3s install, etc.)
cd ansible
ansible-playbook playbooks/update.yml --ask-become-pass
ansible-playbook playbooks/packages.yml --ask-become-pass
ansible-playbook playbooks/k3s.yml --ask-become-pass
# See docs/INSTALLATION.md for full list

# Shell scripts (app deployment + management)
./scripts/homelab.sh deploy        # Deploy the script-managed stacks
./scripts/homelab.sh deploy media  # Deploy specific stack
./scripts/homelab.sh status        # Cluster health check
./scripts/homelab.sh logs <svc>    # View service logs
```

`homelab.sh deploy` covers only the components `deploy-applications.sh` knows
about: `infrastructure`, `cloud`, `media`, `location` (behind
`ENABLE_LOCATION_SERVICES`) and `utilities`. The **automation**, **games**,
**monitoring** and **boinc** stacks are deployed separately with `kubectl apply
-k` or Helm — see the per-app READMEs and [Installation](docs/INSTALLATION.md).

## Adding Nodes

```bash
./scripts/manage-nodes.sh add <hostname> --role server  # Control plane
./scripts/manage-nodes.sh add <hostname>                # Worker node

# Add node to ansible/inventory.yml, then run Ansible playbooks (see docs/INSTALLATION.md)
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
