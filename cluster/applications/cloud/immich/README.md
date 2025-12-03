# Immich - Self-Hosted Photo and Video Management

Immich is a high-performance self-hosted photo and video management solution, similar to Google Photos.

## Architecture

- **Database**: PostgreSQL 16 with pgvecto-rs extension (for ML features)
- **Cache**: Redis 7.2
- **Storage**: NFS-backed persistent storage
  - Library: `/media/data/immich/library` (exported via `/exports/immich`)
  - Config: `/media/data/immich/config`
- **Deployment**: Helm chart from official Immich repository

## Storage Setup

The storage is set up with mergerFS support:
- Local path: `/media/data/immich/`
- NFS export: `/exports/immich` (bind mount)
- NFS share accessible at: `192.168.1.94:/immich`

## Pre-Deployment Steps

1. **Generate strong passwords**:
   ```bash
   openssl rand -base64 32
   ```

2. **Update secrets**:
   Edit `secrets.yaml` and replace `CHANGE_ME_STRONG_PASSWORD` with your generated passwords.

## Deployment

### Quick Deploy

Run the deployment script:
```bash
./cluster/applications/media-stack/immich/deploy.sh
```

### Manual Deployment

1. **Apply supporting resources**:
   ```bash
   kubectl apply -f cluster/applications/media-stack/immich/secrets.yaml
   kubectl apply -f cluster/applications/media-stack/immich/storage-pvs.yaml
   kubectl apply -f cluster/applications/media-stack/immich/storage-pvcs.yaml
   kubectl apply -f cluster/applications/media-stack/immich/postgres.yaml
   kubectl apply -f cluster/applications/media-stack/immich/redis.yaml
   kubectl apply -f cluster/applications/media-stack/immich/middleware.yaml
   ```

2. **Deploy Immich via Helm**:
   ```bash
   helm repo add immich https://immich-app.github.io/immich-charts
   helm repo update

   helm upgrade --install immich immich/immich \
       --namespace media \
       --values cluster/applications/media-stack/immich/values.yaml \
       --wait
   ```

3. **Apply ingress**:
   ```bash
   kubectl apply -f cluster/applications/media-stack/ingress.yaml
   ```

## Access

- **URL**: https://immich.cliff.li
- **DNS**: Ensure `immich.cliff.li` points to your cluster's ingress IP

## Post-Deployment

1. Access the web interface at https://immich.cliff.li
2. Complete the initial setup wizard
3. Create your admin account
4. Download the Immich mobile app (iOS/Android)
5. Configure the app to connect to `https://immich.cliff.li`

## Machine Learning

Machine learning is **disabled by default** to save resources. To enable:

1. Edit `values.yaml` and set:
   ```yaml
   env:
     IMMICH_MACHINE_LEARNING_ENABLED: "true"

   machine-learning:
     enabled: true
     persistence:
       cache:
         enabled: true
         size: 10Gi
   ```

2. Upgrade the Helm release:
   ```bash
   helm upgrade immich immich/immich \
       --namespace media \
       --values cluster/applications/media-stack/immich/values.yaml
   ```

## Monitoring

Check deployment status:
```bash
# View all Immich pods
kubectl get pods -n media -l app.kubernetes.io/name=immich

# View logs
kubectl logs -n media -l app.kubernetes.io/name=immich-server -f

# Check PostgreSQL
kubectl logs -n media -l app=immich-postgres

# Check Redis
kubectl logs -n media -l app=immich-redis
```

## Maintenance

### Backup

Important data to backup:
- PostgreSQL database: `immich-postgres-0` PVC
- Photo library: `/media/data/immich/library`
- Config: `/media/data/immich/config`

### Upgrade

Update to the latest Immich version:
```bash
helm repo update
helm upgrade immich immich/immich \
    --namespace media \
    --values cluster/applications/media-stack/immich/values.yaml
```

## Troubleshooting

### Pod not starting
```bash
kubectl describe pod -n media -l app.kubernetes.io/name=immich-server
kubectl logs -n media -l app.kubernetes.io/name=immich-server
```

### Database connection issues
```bash
# Check PostgreSQL is running
kubectl get pods -n media -l app=immich-postgres

# Check PostgreSQL logs
kubectl logs -n media immich-postgres-0

# Test database connectivity
kubectl exec -n media immich-postgres-0 -- psql -U immich -d immich -c "SELECT version();"
```

### Storage issues
```bash
# Check PVCs
kubectl get pvc -n media | grep immich

# Check PVs
kubectl get pv | grep immich

# Verify NFS mount on node
showmount -e 192.168.1.94
```

## Resources

- [Immich Documentation](https://immich.app/docs)
- [Immich GitHub](https://github.com/immich-app/immich)
- [Immich Helm Charts](https://github.com/immich-app/immich-charts)
