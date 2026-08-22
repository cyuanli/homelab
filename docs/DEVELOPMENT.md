# Development Guide

## Cluster Directory Structure

```
cluster/
├── manifests/              # Cluster bootstrap (plain kubectl apply)
│   ├── namespaces/        # Core namespaces
│   ├── traefik/           # Ingress controller (DaemonSet, infrastructure ns)
│   ├── cert-manager/      # Let's Encrypt ClusterIssuers
│   └── storage/           # local-path + Nextcloud/Postgres PVs
├── infrastructure/         # nfs-direct StorageClass, priority classes
└── applications/           # Application deployments
    ├── automation/        # Home Assistant, MariaDB, Mosquitto, Zigbee2MQTT
    ├── boinc/             # BOINC distributed computing (not deployed)
    ├── cloud/             # Nextcloud, Immich
    ├── games/             # Minecraft worlds, mc-router, backup CronJob
    ├── location/          # OwnTracks
    ├── media-stack/       # Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent
    ├── monitoring/        # kube-prometheus-stack values, alert rules, blackbox
    └── utilities/         # Syncthing, Whoami
```

### Deployment mechanism per app

Not everything is Kustomize — know which tool owns a given app before editing:

| App | Managed by |
|-----|-----------|
| media-stack, utilities, location, automation (mosquitto/zigbee2mqtt/mariadb), nextcloud, boinc | Kustomize (`kubectl apply -k`) |
| Immich | Helm `immich/immich` + Kustomize for PVs/PVCs/postgres/redis/ingress |
| Home Assistant | Helm chart + Kustomize for PVs/PVCs/ingress |
| Minecraft worlds | Helm `itzg/minecraft`, one release per world |
| Prometheus/Grafana/Alertmanager | Helm `kube-prometheus-stack` |
| blackbox-exporter | Helm `prometheus-blackbox-exporter` |
| Traefik, cert-manager issuers, namespaces, storage | plain `kubectl apply -f` |

Check what a release actually uses with `helm list -A`.

## Adding New Services

1. **Create application directory**:
   ```bash
   mkdir -p cluster/applications/<category>/<service-name>
   ```

2. **Create manifests** (use existing services as templates):
   - `deployment.yaml` or `<service>.yaml`
   - `service.yaml` (if needed)
   - `ingress.yaml` (for external access)
   - `kustomization.yaml`
   - `storage-pvs.yaml` / `storage-pvcs.yaml` (if using NFS storage)

3. **Ingress template**:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: myservice
     namespace: mynamespace
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt-production
   spec:
     ingressClassName: traefik
     rules:
     - host: myservice.cliff.li
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: myservice
               port:
                 number: 8080
     tls:
     - hosts:
       - myservice.cliff.li
       secretName: myservice-tls
   ```

4. **Deploy**:
   ```bash
   kubectl apply -k cluster/applications/<category>/<service-name>/
   ```

## Scripts Reference

Host-level setup (packages, firewall, K3s, NFS, systemd timers) is managed by Ansible playbooks in `ansible/`. See [Installation Guide](INSTALLATION.md) for details.

Shell scripts in `scripts/` handle app deployment and day-to-day management:

| Script | Purpose |
|--------|---------|
| `homelab.sh` | Main CLI orchestrator |
| `deploy-applications.sh` | Application deployment to K3s (infrastructure, cloud, media, location, utilities) |
| `manage-nodes.sh` | Cluster node management |
| `monitor-storage.sh` | SnapRAID disk health + server-side NFS export checks (run by `disk-monitor.timer`) |
| `auto-remediate.sh` | Restarts deployments on `ServiceDown` alerts (run by `auto-remediate.timer`) |
| `backup-notify.sh` | Borgmatic notification hook |
| `snapraid-notify.sh` | SnapRAID metrics export |
| `50-tailscale-udp-gro` | NetworkManager dispatcher hook, tunes UDP GRO for Tailscale |
| `utils/common.sh` | Shared utility functions |
| `utils/metrics.sh` | Prometheus metrics helpers |

## Script Conventions

Scripts use shared functions from `scripts/utils/common.sh`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

log_info "Info message"
log_success "Done"
log_warning "Warning"
log_error "Error"
log_step "Section heading"

load_config              # Loads nodes/$(hostname)/config.env.local; exits if absent
check_not_root           # Refuse to run as root
wait_for_deployment <ns> <name>
wait_for_namespace_ready <ns>
```

## Testing Changes

```bash
# Dry-run deployment
kubectl apply --dry-run=client -k cluster/applications/<service>/

# Check logs
kubectl logs -n <namespace> deployment/<service> -f

# Restart after changes
kubectl rollout restart deployment/<service> -n <namespace>
```

## NFS Storage

For services needing persistent storage on the NAS:

1. Create the directory on the storage node (`cyl-homelab`):
   - bulk / read-heavy data → `sudo mkdir -p /media/data/<service>`
   - write-heavy config or cache → `sudo mkdir -p /srv/app-storage/<service>`
2. Create a PV with `storageClassName: nfs-direct` pointing at the NFS path
   (see existing `storage-pvs.yaml` files)
3. Create a matching PVC

NFS server: `192.168.1.94`. The export root is `/exports`, but PV paths are
written **relative to the NFSv4 pseudo-root** — i.e. `/media/<service>` for the
`/exports/media` bind (`fsid=1`) and `/configs/<service>` for the
`/exports/configs` bind (`fsid=2`). Existing exports are listed in
`config/system-configs/exports`. That file is Ansible-managed — adding a new
top-level export means editing the bind mount in `/etc/fstab` on the host and
the repo's `exports` file, then re-running
`ansible-playbook playbooks/nfs-storage.yml --limit cyl-homelab`, which copies
it and runs `exportfs -ra`. Exports are scoped to the 7 cluster node IPs, so a
new node must be added to all three export lines before it can mount anything.

## Common Commands

```bash
kubectl get pods -A                                    # All pods
kubectl logs -n <ns> deployment/<svc> -f              # Service logs
kubectl rollout restart deployment/<svc> -n <ns>      # Restart
kubectl scale deployment/<svc> -n <ns> --replicas=0   # Stop
kubectl get certificates -A                            # SSL certs
kubectl get pvc -A                                     # Storage claims
```
