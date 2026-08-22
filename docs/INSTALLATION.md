# Installation Guide

## Prerequisites

- Debian-based Linux with sudo access. All current nodes run **Debian 13
  (trixie)**; the playbooks were originally written against Debian 12 and should
  still work there.
- Tailscale account ([tailscale.com](https://tailscale.com))
- Domain name (for SSL certificates)
- Ansible on the control machine, plus `kubectl` and `helm` for the K8s steps
- VPS with public IP (optional, for external access)

Current cluster runs K3s `v1.33.5+k3s1` with containerd `2.1.4-k3s1`.

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

HOMELAB_USER="your-username"
HOMELAB_UID="1000"  # Run: id -u
HOMELAB_GID="1000"  # Run: id -g

DATA_ROOT="/media/data"
K8S_STORAGE_ROOT="/opt/k3s-storage"

NODE_ROLE="server"
```

### Run Setup

Host-level configuration is managed with Ansible. Run playbooks from the `ansible/` directory:

```bash
cd ansible

# System packages, firewall, directories, permissions, Tailscale
ansible-playbook playbooks/update.yml --ask-become-pass
ansible-playbook playbooks/packages.yml --ask-become-pass
ansible-playbook playbooks/ufw.yml --ask-become-pass
ansible-playbook playbooks/directories.yml --ask-become-pass
ansible-playbook playbooks/user-permissions.yml --ask-become-pass
ansible-playbook playbooks/tailscale.yml --ask-become-pass -e tailscale_authkey=tskey-auth-...

# Docker/LXCFS, K8s tools, NFS, systemd timers
ansible-playbook playbooks/docker.yml --ask-become-pass
ansible-playbook playbooks/k8s-tools.yml --ask-become-pass
ansible-playbook playbooks/nfs-storage.yml --ask-become-pass
ansible-playbook playbooks/systemd-timers.yml --ask-become-pass

# K3s cluster (requires vault password for cluster token)
ansible-playbook playbooks/k3s.yml --ask-become-pass --ask-vault-pass
```

Or run the whole sequence at once — `site.yml` imports exactly the playbooks
above, in that order:

```bash
ansible-playbook site.yml --ask-become-pass --ask-vault-pass \
  -e tailscale_authkey=tskey-auth-...
```

Use `--limit <hostname>` to target a single node.

Add the new node to `ansible/inventory.yml` first — group membership decides
what a node gets: `servers` (K3s control plane), `agents` (K3s workers),
`storage` (NFS server, Docker, SnapRAID/disk timers), `monitoring`
(auto-remediate timer), `backup` (borgmatic).

`playbooks/mergerfs-service.yml` is **deliberately not** in `site.yml`. It
installs the mergerfs auto-restart unit without enabling it, because adopting it
requires manually commenting out the mergerfs line in `/etc/fstab` first. See
[Storage](STORAGE.md) → "Storage durability".

### Apply node labels

BOINC's overlays and some scheduling rules key off node labels:

```bash
kubectl apply -f nodes/<hostname>/labels.yaml
```

### Bootstrap K8s Infrastructure (first server only)

After K3s is running, apply the core K8s manifests:

```bash
kubectl apply -f cluster/manifests/namespaces/
kubectl apply -f cluster/manifests/storage/
kubectl apply -f cluster/infrastructure/storage/nfs-direct-storageclass.yaml
kubectl apply -k cluster/infrastructure/priority-classes/
kubectl apply -f cluster/manifests/traefik/
```

cert-manager itself is **not** vendored in this repo — only the ClusterIssuers
are. Install it first, then apply the issuers (which reference `ACME_EMAIL` and
your domain). The running cluster has `v1.16.2` installed from the upstream
static manifest (there is no cert-manager Helm release):

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl apply -f cluster/manifests/cert-manager/
```

### Deploy Applications

Script-managed stacks (`infrastructure`, `cloud`, `media`, `location`,
`utilities`):

```bash
./scripts/homelab.sh deploy
```

The remaining stacks are applied directly. Helm-based ones need their repo added
first:

```bash
# Automation — namespace, MariaDB, Mosquitto, Zigbee2MQTT, plus Home
# Assistant's PVs/PVCs and ingress (the parent kustomization includes them all)
kubectl apply -k cluster/applications/automation/

# Home Assistant itself is a Helm release on top of the above
helm repo add pajikos http://pajikos.github.io/home-assistant-helm-chart/
helm upgrade --install home-assistant pajikos/home-assistant -n automation \
  -f cluster/applications/automation/home-assistant/values.yaml

# Monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f cluster/applications/monitoring/kube-prometheus-stack-values.yaml
helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  -n monitoring -f cluster/applications/monitoring/blackbox-exporter-values.yaml
kubectl apply -f cluster/applications/monitoring/alertmanager-discord.yaml
kubectl apply -f cluster/applications/monitoring/prometheus-rules-*.yaml
kubectl apply -f cluster/applications/monitoring/storage-pvs.yaml \
              -f cluster/applications/monitoring/storage-pvcs.yaml

# Games — see cluster/applications/games/minecraft/README.md
# Immich — see cluster/applications/cloud/immich/README.md
```

### Verify

```bash
./scripts/homelab.sh status
kubectl get pods -A
helm list -A
```


## Adding More Nodes

```bash
# 1. On first server, generate config for new node
./scripts/manage-nodes.sh add <new-hostname> --role server  # or agent

# 2. Add the node to ansible/inventory.yml in the appropriate groups

# 3. Run Ansible playbooks against the new node
cd ansible
ansible-playbook site.yml --ask-become-pass --limit <new-hostname> -e tailscale_authkey=tskey-auth-...
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
cd ansible && ansible-playbook playbooks/k3s.yml --ask-become-pass --ask-vault-pass --limit $(hostname)
```
