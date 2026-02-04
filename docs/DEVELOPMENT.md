# Development Guide

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
