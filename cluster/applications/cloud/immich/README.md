# Immich - Self-Hosted Photo and Video Management

Immich is a high-performance self-hosted photo and video management solution, similar to Google Photos.

> ⚠️ **Current state (checked 2026-08-21):** the Helm release is in `failed`
> status at revision 21 (chart `immich-0.10.3`, app `v2.0.0`, last touched
> 2025-12-09) even though `immich-server`, `immich-machine-learning` and
> `immich-redis` are all running 1/1. A failed release blocks nothing today but
> will complicate the next `helm upgrade`. Inspect with
> `helm status immich -n cloud` and `helm history immich -n cloud` before
> upgrading; a `helm rollback` to the last good revision may be needed first.

## Architecture

- **Database**: PostgreSQL 16 with pgvecto-rs extension (for ML features)
- **Cache**: Redis 7.2
- **Storage**: Split storage for optimal performance
  - **Photo Library** (HDD): `/media/data/immich/library` - exported via NFS as `192.168.1.94:/immich/library`
  - **Thumbnails** (SSD): `/srv/app-storage/immich/thumbs` - exported via NFS as `192.168.1.94:/configs/immich/thumbs`
  - **Encoded Video** (SSD): `/srv/app-storage/immich/encoded-video` - exported via NFS as `192.168.1.94:/configs/immich/encoded-video`
  - **Profile Pictures** (SSD): `/srv/app-storage/immich/profile` - exported via NFS as `192.168.1.94:/configs/immich/profile`
- **Deployment**: Helm chart from official Immich repository

## Storage Setup

Immich uses a **split storage architecture** for optimal performance:

### HDD Storage (mergerFS pool - 6.8TB)
- **Photo/Video Library**: Large media files, read-heavy workload
- **User Uploads**: Infrequent writes
- **Backups**: Periodic writes

### SSD Storage (/srv/app-storage - 432GB)
- **Thumbnails**: ~7GB, frequent generation during photo processing
- **Encoded Videos**: ~15GB, frequent transcoding operations
- **Profile Pictures**: Minimal size, occasional writes

This configuration reduces HDD wear by moving ~22GB of high-frequency write operations to SSD while keeping the bulk photo library on cost-effective HDD storage

## Pre-Deployment Steps

1. **Generate strong passwords**:
   ```bash
   openssl rand -base64 32
   ```

2. **Update secrets**:
   Edit `secrets.yaml` and replace `CHANGE_ME_STRONG_PASSWORD` with your generated passwords.

## Deployment

Immich is split across two tools: **Kustomize** owns the supporting resources
(secrets, PVs/PVCs, PostgreSQL, Redis, ingress, middlewares) and **Helm** owns
the Immich application itself.

1. **Apply the supporting resources with Kustomize** — this covers everything in
   `kustomization.yaml`, including the ingress and middlewares:
   ```bash
   kubectl apply -k cluster/applications/cloud/immich/
   ```

   Or individually:
   ```bash
   kubectl apply -f cluster/applications/cloud/immich/secrets.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-pvs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-pvcs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-cache-pvs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-cache-pvcs.yaml
   kubectl apply -f cluster/applications/cloud/immich/postgres.yaml
   kubectl apply -f cluster/applications/cloud/immich/redis.yaml
   kubectl apply -f cluster/applications/cloud/immich/middleware.yaml
   kubectl apply -f cluster/applications/cloud/immich/ingress.yaml
   ```

2. **Deploy Immich via Helm**:
   ```bash
   helm repo add immich https://immich-app.github.io/immich-charts
   helm repo update

   helm upgrade --install immich immich/immich \
       --namespace cloud \
       --values cluster/applications/cloud/immich/values.yaml \
       --wait
   ```

## Access

- **URL**: https://photos.cliff.li
- **DNS**: Ensure `photos.cliff.li` points to your cluster's ingress IP

## Post-Deployment

1. Access the web interface at https://photos.cliff.li
2. Complete the initial setup wizard
3. Create your admin account
4. Download the Immich mobile app (iOS/Android)
5. Configure the app to connect to `https://photos.cliff.li`

## Machine Learning

Machine learning is **enabled** (`machine-learning.enabled: true` in
`values.yaml`); the `immich-machine-learning` deployment runs in the `cloud`
namespace. To disable it and reclaim the resources, set `enabled: false` and
upgrade the release:

```bash
helm upgrade immich immich/immich \
    --namespace cloud \
    --values cluster/applications/cloud/immich/values.yaml
```

## Monitoring

Check deployment status:
```bash
# View all Immich pods
kubectl get pods -n cloud -l app.kubernetes.io/instance=immich

# View logs
kubectl logs -n cloud deploy/immich-server -f

# Check PostgreSQL
kubectl logs -n cloud immich-postgres-0

# Check Redis
kubectl logs -n cloud deploy/immich-redis
```

## Maintenance

### Backup

Important data to backup:
- PostgreSQL database: `immich-postgres-0` PVC (local-path storage)
- Photo library: `/media/data/immich/library` (HDD)
- SSD cache (optional, can be regenerated):
  - `/srv/app-storage/immich/thumbs`
  - `/srv/app-storage/immich/encoded-video`
  - `/srv/app-storage/immich/profile`

### Upgrade

Update to the latest Immich version:
```bash
helm repo update
helm upgrade immich immich/immich \
    --namespace cloud \
    --values cluster/applications/cloud/immich/values.yaml
```

## Troubleshooting

### Pod not starting
```bash
kubectl describe pod -n cloud -l app.kubernetes.io/instance=immich
kubectl logs -n cloud deploy/immich-server
```

### Database connection issues
```bash
# Check PostgreSQL is running
kubectl get pods -n cloud -l app=immich-postgres

# Check PostgreSQL logs
kubectl logs -n cloud immich-postgres-0

# Test database connectivity
kubectl exec -n cloud immich-postgres-0 -- psql -U immich -d immich -c "SELECT version();"
```

### Storage issues
```bash
# Check PVCs (should show library + 3 cache PVCs)
kubectl get pvc -n cloud | grep immich

# Check PVs
kubectl get pv | grep immich

# Verify mounts inside container
kubectl exec -n cloud deploy/immich-server -- df -h | grep /data

# Check NFS exports
showmount -e 192.168.1.94
```

## Resources

- [Immich Documentation](https://immich.app/docs)
- [Immich GitHub](https://github.com/immich-app/immich)
- [Immich Helm Charts](https://github.com/immich-app/immich-charts)
