# K3s Cluster Configuration

## Directory Structure

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

## Deployment

```bash
# Deploy all
./scripts/homelab.sh deploy

# Deploy specific stack
kubectl apply -k cluster/applications/media-stack/

# Deploy single service
kubectl apply -k cluster/applications/media-stack/jellyfin/
```

## Adding a Service

1. Create directory: `cluster/applications/<category>/<service>/`
2. Add manifests (use existing services as templates)
3. Deploy: `kubectl apply -k cluster/applications/<category>/<service>/`

### Ingress Template

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

## Common Commands

```bash
kubectl get pods -A                                    # All pods
kubectl logs -n <ns> deployment/<svc> -f              # Service logs
kubectl rollout restart deployment/<svc> -n <ns>      # Restart
kubectl scale deployment/<svc> -n <ns> --replicas=0   # Stop
kubectl get certificates -A                            # SSL certs
kubectl get pvc -A                                     # Storage claims
```
