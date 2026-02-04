# Installation Guide

## Prerequisites

- Fresh Debian 12 or Ubuntu 22.04 LTS
- Root/sudo access
- Tailscale account ([tailscale.com](https://tailscale.com))
- Domain name (for SSL certificates)
- VPS with public IP (optional, for external access)

## Quick Install

```bash
# 1. Clone repo
git clone <repo-url> homelab && cd homelab

# 2. Create node config
mkdir -p nodes/$(hostname)
cp config/templates/node-config.env.template nodes/$(hostname)/config.env.local
nano nodes/$(hostname)/config.env.local
```

### Required Config Values

```bash
DOMAIN="your-domain.com"
ACME_EMAIL="you@your-domain.com"
TAILSCALE_AUTHKEY="tskey-auth-..."  # From Tailscale admin console

HOMELAB_USER="your-username"
HOMELAB_UID="1000"  # Run: id -u
HOMELAB_GID="1000"  # Run: id -g

DATA_ROOT="/media/data"
K8S_STORAGE_ROOT="/opt/k3s-storage"

NODE_ROLE="server"
```

### Run Setup

```bash
./scripts/homelab.sh setup-all
```

This installs:
- System packages (curl, git, etc.)
- UFW firewall
- Tailscale VPN
- K3s cluster
- Core infrastructure (Traefik, cert-manager)
- Applications

### Verify

```bash
./scripts/homelab.sh status
kubectl get pods -A
```

## Adding More Nodes

```bash
# On first server, generate config for new node
./scripts/manage-nodes.sh add <new-hostname> --role server  # or agent

# Copy repo to new node and run
./scripts/homelab.sh setup-system
./scripts/homelab.sh setup-cluster
```

For HA: use 3 or 5 server nodes (odd number for etcd quorum).

## VPS Proxy (Optional)

For external access via VPS:

```bash
# On VPS
cd homelab/vps
cp config/vps.env config/vps.env.local
# Edit: HOME_PC_NAMES="node1 node2 node3"
sudo bash scripts/setup.sh
```

Configure DNS: `*.your-domain.com → VPS_PUBLIC_IP`

## Troubleshooting

```bash
# Tailscale auth
sudo tailscale status
sudo tailscale up --authkey=<key>

# Pod issues
kubectl get pods -A
kubectl describe pod <name> -n <namespace>

# Storage permissions
sudo chown -R $USER:$USER /media/data
```

## Recovery

```bash
# Clean reinstall
sudo /usr/local/bin/k3s-uninstall.sh
./scripts/homelab.sh setup-all
```
