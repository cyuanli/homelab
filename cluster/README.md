# K3s Cluster Configuration

This directory contains the Kubernetes manifests and configuration for your homelab K3s cluster.

## Directory Structure

```
cluster/
├── bootstrap/              # Initial cluster setup scripts
├── manifests/              # Core infrastructure
│   ├── namespaces/        # Kubernetes namespaces
│   ├── traefik/           # Ingress controller
│   ├── cert-manager/      # SSL certificate management
│   └── storage/           # Persistent volume configuration
└── applications/           # Application deployments
    ├── cloud/             # Cloud services (Nextcloud)
    ├── location/          # Location services (OwnTracks)
    ├── media-stack/       # Media services (Jellyfin, Sonarr, etc.)
    └── utilities/         # Utility services (Whoami, etc.)
```

## Quick Start

The cluster is managed through the main homelab orchestrator. These commands should be run from the repository root:

```bash
# Deploy core infrastructure
./scripts/homelab.sh setup-cluster

# Deploy all applications
./scripts/homelab.sh deploy

# Deploy specific application stack
./scripts/homelab.sh deploy media
./scripts/homelab.sh deploy cloud
```

## Cluster Management

### Application Deployment

**Deploy Individual Applications**
```bash
# Deploy using kustomize directly
kubectl apply -k cluster/applications/media-stack/jellyfin/

# Deploy entire media stack
kubectl apply -k cluster/applications/media-stack/

# Deploy with the homelab script (recommended)
./scripts/homelab.sh deploy jellyfin
```

**Check Deployment Status**
```bash
# View all pods
kubectl get pods -A

# Check specific namespace
kubectl get pods -n media
kubectl get pods -n cloud

# Check deployment rollout
kubectl rollout status deployment/jellyfin -n media
```

### Service Management

**Scale Applications**
```bash
# Scale deployment
kubectl scale deployment/jellyfin -n media --replicas=2

# Scale to zero (stop service)
kubectl scale deployment/jellyfin -n media --replicas=0
```

**Rolling Updates**
```bash
# Update container image
kubectl set image deployment/jellyfin jellyfin=jellyfin/jellyfin:10.8.13 -n media

# Restart deployment (force rolling update)
kubectl rollout restart deployment/jellyfin -n media

# Check rollout history
kubectl rollout history deployment/jellyfin -n media
```

### Configuration Management

**Environment Variables**
Most manifests support environment variable substitution from the main configuration:

```yaml
# Example in deployment manifest
env:
- name: PUID
  value: "${PUID}"
- name: PGID
  value: "${PGID}"
volumeMounts:
- name: media
  mountPath: /media
volumes:
- name: media
  hostPath:
    path: "${DATA_ROOT}/media"
```

**Secrets and ConfigMaps**
```bash
# View secrets
kubectl get secrets -A

# View config maps
kubectl get configmaps -A

# Update secret
kubectl create secret generic app-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Storage

The cluster uses local storage with the following directories:

**K8s Persistent Storage** (`/opt/k3s-storage/`)
- `traefik-acme/` - SSL certificates
- `nextcloud-data/` - Nextcloud application data
- `nextcloud-files/` - User files
- `postgres-data/` - Database storage
- `redis-data/` - Cache storage

**Media Storage** (`/media/data/`)
- `media/` - Media files (movies, TV, music)
- `downloads/` - Download staging area

**Storage Management**
```bash
# Check storage usage
df -h /opt/k3s-storage
df -h /media/data

# Check persistent volumes
kubectl get pv
kubectl get pvc -A

# Check storage class
kubectl get storageclass
```

## Network Configuration

### Ingress

Traefik handles ingress with automatic HTTPS via Let's Encrypt:

```yaml
# Example ingress configuration
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jellyfin
  namespace: media
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  rules:
  - host: jellyfin.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jellyfin
            port:
              number: 8096
  tls:
  - hosts:
    - jellyfin.your-domain.com
    secretName: jellyfin-tls
```

### Service Discovery

Services are automatically discovered by Traefik through Kubernetes service definitions:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: media
spec:
  selector:
    app: jellyfin
  ports:
  - name: http
    port: 8096
    targetPort: 8096
```

### External Access

- **VPS Proxy**: Nginx on VPS forwards traffic via Tailscale
- **Direct Access**: Services accessible on cluster nodes (for internal use)
- **SSL Termination**: Let's Encrypt certificates via Traefik

## Security

### Namespace Isolation

Applications are isolated in separate namespaces:
- `media` - Media stack services
- `cloud` - Nextcloud and related services
- `location` - OwnTracks services
- `utilities` - Utility and test services

### Resource Limits

All containers have resource limits applied:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### Secrets Management

Sensitive configuration is stored in Kubernetes secrets:

```bash
# Create secret from file
kubectl create secret generic app-config \
  --from-file=config.conf

# Create secret from literals
kubectl create secret generic app-credentials \
  --from-literal=username=admin \
  --from-literal=password=secret
```

## Monitoring and Logging

### Health Checks

```bash
# Check cluster health
kubectl get nodes
kubectl get componentstatuses

# Check pod health
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>

# Check events
kubectl get events --sort-by='.lastTimestamp' -A
```

### Logs

```bash
# View pod logs
kubectl logs -n media deployment/jellyfin
kubectl logs -n media deployment/jellyfin -f  # Follow logs

# View previous container logs
kubectl logs -n media deployment/jellyfin --previous

# View logs from all containers in deployment
kubectl logs -n media deployment/jellyfin --all-containers=true
```

### Resource Usage

```bash
# Check node resource usage
kubectl top nodes

# Check pod resource usage
kubectl top pods -A
kubectl top pods -n media
```

## Troubleshooting

### Common Issues

**Pods Not Starting**
```bash
# Check pod status and events
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>

# Check node resources
kubectl top nodes
kubectl describe node <node-name>
```

**Storage Issues**
```bash
# Check persistent volume claims
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n <namespace>

# Check storage permissions
ls -la /opt/k3s-storage/
sudo chown -R 1000:1000 /opt/k3s-storage/<service>/
```

**Network Issues**
```bash
# Check services
kubectl get svc -A
kubectl describe svc <service-name> -n <namespace>

# Check ingress
kubectl get ingress -A
kubectl describe ingress <ingress-name> -n <namespace>

# Test internal connectivity
kubectl exec -it -n utilities deployment/whoami -- curl http://jellyfin.media:8096
```

**Certificate Issues**
```bash
# Check certificates
kubectl get certificates -A
kubectl describe certificate <cert-name> -n <namespace>

# Check Traefik logs
kubectl logs -n kube-system deployment/traefik

# Force certificate renewal
kubectl delete certificate <cert-name> -n <namespace>
```

### Debug Commands

**Pod Debugging**
```bash
# Get shell in running pod
kubectl exec -it -n media deployment/jellyfin -- /bin/bash

# Run debug pod
kubectl run debug --image=busybox -it --rm -- /bin/sh

# Port forward for local access
kubectl port-forward -n media deployment/jellyfin 8096:8096
```

**Network Debugging**
```bash
# Test DNS resolution
kubectl exec -it -n utilities deployment/whoami -- nslookup google.com

# Test service connectivity
kubectl exec -it -n utilities deployment/whoami -- curl http://jellyfin.media:8096

# Check cluster DNS
kubectl get svc -n kube-system | grep dns
```

## Customization

### Adding New Services

1. **Create Application Directory**
   ```bash
   mkdir -p cluster/applications/category/new-service
   ```

2. **Create Manifests**
   - `deployment.yaml` - Main application deployment
   - `service.yaml` - Kubernetes service definition
   - `ingress.yaml` - External access configuration
   - `kustomization.yaml` - Kustomize configuration

3. **Add to Deployment Scripts**
   Update `scripts/deploy-applications.sh` to include the new service.

### Modifying Existing Services

1. **Edit Manifests**
   ```bash
   # Edit deployment configuration
   nano cluster/applications/media-stack/jellyfin/jellyfin.yaml
   ```

2. **Apply Changes**
   ```bash
   # Apply with kustomize
   kubectl apply -k cluster/applications/media-stack/jellyfin/

   # Or use homelab script
   ./scripts/homelab.sh deploy jellyfin
   ```

### Environment-Specific Configurations

Use Kustomize overlays for different environments:

```bash
# Create overlay directory
mkdir -p cluster/applications/media-stack/jellyfin/overlays/development

# Create development-specific configuration
cat << EOF > cluster/applications/media-stack/jellyfin/overlays/development/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../

patchesStrategicMerge:
  - development-config.yaml
EOF
```

## Advanced Configuration

### Multi-Node Cluster

For multi-node setups:

1. **Add Worker Nodes**
   ```bash
   ./scripts/manage-nodes.sh add worker2 192.168.1.102
   ```

2. **Node Affinity**
   ```yaml
   # Add to deployment spec
   affinity:
     nodeAffinity:
       requiredDuringSchedulingIgnoredDuringExecution:
         nodeSelectorTerms:
         - matchExpressions:
           - key: node-role.kubernetes.io/worker
             operator: Exists
   ```

### Custom Storage Classes

For advanced storage configurations:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: rancher.io/local-path
parameters:
  nodePath: /opt/fast-storage
volumeBindingMode: WaitForFirstConsumer
```

This cluster configuration provides a robust foundation for running containerized applications in your homelab environment while maintaining flexibility for customization and scaling.