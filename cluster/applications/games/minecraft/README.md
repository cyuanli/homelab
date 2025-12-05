# Minecraft Fabric Server

Kubernetes deployment of a Minecraft Java Edition server running Fabric mod loader.

## Architecture

- **Server Type**: Fabric (latest)
- **Storage**: Local SSD on cyl-mitx (50Gi)
- **Backups**: NFS storage with daily automated backups
- **Resources**: 1000m CPU request, 2Gi memory request (no limits)

## Storage Strategy

### Active Data
- **Location**: Local SSD on `cyl-mitx` node
- **Type**: `local-path` StorageClass
- **Why**: Fast chunk loading/saving, prevents HDD wear

### Backups
- **Location**: NFS at `192.168.1.94:/games/minecraft/backups`
- **Schedule**: Daily at 1 AM UTC
- **Retention**: Last 7 daily backups
- **Method**: Kubernetes CronJob with rsync

## Deployment

### 1. Add Helm Repository
```bash
helm repo add itzg https://itzg.github.io/minecraft-server-charts/
helm repo update
```

### 2. Create Namespace
```bash
kubectl create namespace games
```

### 3. Create NFS directory on storage server
**Note**: If you ran `scripts/setup-nfs-storage.sh`, this directory was created automatically. Otherwise, create it manually on the NFS server (192.168.1.94):
```bash
sudo mkdir -p /media/data/games/minecraft/backups
sudo chmod 755 /media/data/games/minecraft/backups
```

### 4. Apply Storage Resources
```bash
kubectl apply -f backup-storage.yaml
```

### 5. Install Minecraft Server
```bash
helm install minecraft itzg/minecraft \
  -n games \
  -f values.yaml
```

### 6. Deploy Backup CronJob
```bash
kubectl apply -f backup-cronjob.yaml
```

## Access

Get the LoadBalancer IP:
```bash
kubectl get svc -n games minecraft-minecraft
```

Connect in Minecraft client using: `<LOADBALANCER_IP>:25565`

## Management

### View Logs
```bash
kubectl logs -n games -l app=minecraft-minecraft -f
```

### Console Commands
```bash
kubectl exec -n games -it deployment/minecraft-minecraft -- rcon-cli
```

### Check Backups
```bash
kubectl exec -n games -it deployment/minecraft-minecraft -- ls -lh /backups/daily/
```

### Manual Backup
```bash
kubectl create job -n games --from=cronjob/minecraft-backup minecraft-backup-manual
```

## Restore from Backup

1. Stop the server:
```bash
kubectl scale deployment -n games minecraft-minecraft --replicas=0
```

2. Copy backup to active data (from cyl-mitx node):
```bash
# Find the PVC path
kubectl get pv -o custom-columns=NAME:.metadata.name,PATH:.spec.local.path | grep minecraft

# Copy backup
rsync -av /path/to/nfs/backups/daily/<backup-date>/ /path/to/local-pvc/
```

3. Start the server:
```bash
kubectl scale deployment -n games minecraft-minecraft --replicas=1
```

## Upgrading

```bash
helm upgrade minecraft itzg/minecraft -n games -f values.yaml
```

## Adding Mods

Mods go in the `mods/` directory. You can add them via:
1. kubectl cp
2. Volume mount to separate mod storage
3. Init container that downloads mods
