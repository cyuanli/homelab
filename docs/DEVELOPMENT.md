# Development Guide

## Cluster Directory Structure

```
cluster/
├── manifests/              # Core infrastructure
│   ├── traefik/           # Ingress controller
│   ├── cert-manager/      # SSL certificate management
│   └── storage/           # Storage configuration
├── infrastructure/         # NFS storage, priority classes
└── applications/           # Application deployments
    ├── automation/        # Home Assistant, MariaDB
    ├── boinc/             # BOINC distributed computing
    ├── cloud/             # Nextcloud, Immich
    ├── games/             # Minecraft servers
    ├── location/          # OwnTracks
    ├── media-stack/       # Jellyfin, Sonarr, Radarr, etc.
    ├── monitoring/        # Prometheus, Grafana, Alertmanager
    └── utilities/         # Whoami test service
```

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

| Script | Purpose |
|--------|---------|
| `homelab.sh` | Main CLI orchestrator |
| `setup-system.sh` | System preparation (packages, Docker, Tailscale) |
| `setup-cluster.sh` | K3s cluster installation |
| `setup-nfs-storage.sh` | NFS server/client configuration |
| `deploy-applications.sh` | Application deployment to K3s |
| `manage-nodes.sh` | Cluster node management |
| `monitor-storage.sh` | SnapRAID disk health monitoring |
| `backup-notify.sh` | Borgmatic notification hook |
| `snapraid-notify.sh` | SnapRAID metrics export |
| `utils/common.sh` | Shared utility functions |
| `utils/metrics.sh` | Prometheus metrics helpers |

## Script Conventions

Scripts use shared functions from `scripts/utils/common.sh`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

log_info "Info message"
log_warn "Warning"
log_error "Error"
load_config  # Loads config/homelab.env
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

1. Create directory on storage node: `sudo mkdir -p /media/data/<service>`
2. Create PV pointing to NFS path (see existing `storage-pvs.yaml` files)
3. Create matching PVC

NFS server: `192.168.1.94`, export root: `/exports`

## Common Commands

```bash
kubectl get pods -A                                    # All pods
kubectl logs -n <ns> deployment/<svc> -f              # Service logs
kubectl rollout restart deployment/<svc> -n <ns>      # Restart
kubectl scale deployment/<svc> -n <ns> --replicas=0   # Stop
kubectl get certificates -A                            # SSL certs
kubectl get pvc -A                                     # Storage claims
```
