# Adding New Minecraft Servers

This guide explains how to add additional Minecraft servers to your homelab with mc-router auto-discovery.

## Overview

With mc-router, adding a new Minecraft server is simple:
1. Create a new Helm values file in `worlds/`
2. Deploy the server using Helm
3. Add DNS record for `*.mc.cliff.li`
4. Update backup CronJob to include new world
5. Connect and play!

mc-router automatically discovers the new server within seconds.

## Prerequisites

- mc-router is deployed and running in the `games` namespace
- You have DNS provider access to add records for `*.mc.cliff.li`
- Helm is installed and the itzg/minecraft repo is added

## Step-by-Step Guide

### 1. Create Values File

Create a new values file in the `worlds/` directory:

```bash
cd /home/cyl/homelab/cluster/applications/games/minecraft
cp worlds/cobblestone-values.yaml worlds/creative-values.yaml
```

### 2. Configure Server

Edit `worlds/creative-values.yaml`:

```yaml
# Minecraft Creative Server - Helm Values
# Chart: itzg/minecraft

minecraftServer:
  # Accept EULA
  eula: true

  # Server version and type
  version: "LATEST"
  type: "VANILLA"  # or FABRIC, PAPER, FORGE, etc.

  # Server properties
  difficulty: peaceful
  maxPlayers: 20
  motd: "Creative Building Server"
  mode: creative
  pvp: false
  onlineMode: true

  # World settings
  levelSeed: ""
  viewDistance: 10

  # Server performance
  memory: 4G

  # Network service type (ClusterIP for mc-router)
  serviceType: ClusterIP

# mc-router integration - REQUIRED
serviceAnnotations:
  mc-router.itzg.me/externalServerName: "creative.cliff.li"

# Resource requests
resources:
  requests:
    cpu: 1000m
    memory: 2Gi

# Storage - Local SSD for performance
persistence:
  storageClass: local-path
  dataDir:
    enabled: true
    Size: 50Gi

# Pin to specific node for local storage
nodeSelector:
  kubernetes.io/hostname: cyl-mitx

# Node affinity for local-path storage
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cyl-mitx
```

**Key Configuration Points**:

- **`serviceType: ClusterIP`**: Required for mc-router integration
- **`serviceAnnotations.mc-router.itzg.me/externalServerName`**: Tells mc-router which domain routes to this server
- **`type`**: Choose server type (VANILLA, FABRIC, PAPER, FORGE, SPIGOT, etc.)
- **`mode`**: Choose game mode (survival, creative, adventure, spectator)
- **`nodeSelector`**: Pin to specific node if using local-path storage

### 3. Deploy the Server

Deploy using Helm:

```bash
cd /home/cyl/homelab/cluster/applications/games/minecraft

helm install minecraft-creative itzg/minecraft -n games \
  -f worlds/creative-values.yaml
```

**Verify deployment**:
```bash
kubectl get pods -n games -l app=minecraft-creative
kubectl logs -n games -l app=minecraft-creative -f
```

Wait for the server to start (first start downloads server files, may take 1-2 minutes).

### 4. Verify mc-router Discovery

Check that mc-router discovered the new server:

```bash
# Port forward to mc-router API
kubectl port-forward -n games svc/mc-router 8080:8080 &

# Check routes
curl http://localhost:8080/routes
```

Expected output should include your new server:
```json
{
  "cobblestone.mc.cliff.li": "10.43.141.162:25565",
  "sandstone.mc.cliff.li": "10.43.126.164:25565",
  "creative.mc.cliff.li": "10.43.x.x:25565"
}
```

**Check mc-router logs**:
```bash
kubectl logs -n games deployment/mc-router -f
```

You should see:
```
[INFO] Discovered Minecraft server: minecraft-creative
[INFO] Registered route: creative.mc.cliff.li -> 10.43.x.x:25565
```

### 5. Add DNS Record

Add an A record in your DNS provider pointing to your VPS public IP:

```
creative.cliff.li    A    <YOUR_VPS_PUBLIC_IP>
```

**Wait for DNS propagation** (usually 1-5 minutes):
```bash
# Test DNS resolution
nslookup creative.cliff.li

# Or using dig
dig creative.mc.cliff.li +short
```

### 6. Update Backup CronJob

Edit `backup/cronjob.yaml` to include the new world in the backup script.

**Add volume mount**:
```yaml
volumeMounts:
  - name: cobblestone-data
    mountPath: /data/cobblestone
    readOnly: true
  - name: sandstone-data
    mountPath: /data/sandstone
    readOnly: true
  - name: creative-data  # ADD THIS
    mountPath: /data/creative
    readOnly: true
  - name: minecraft-backups
    mountPath: /backups
    subPath: games/minecraft/backups
```

**Add volume**:
```yaml
volumes:
  - name: cobblestone-data
    persistentVolumeClaim:
      claimName: minecraft-cobblestone-datadir
  - name: sandstone-data
    persistentVolumeClaim:
      claimName: minecraft-sandstone-datadir
  - name: creative-data  # ADD THIS
    persistentVolumeClaim:
      claimName: minecraft-creative-datadir
  - name: minecraft-backups
    persistentVolumeClaim:
      claimName: minecraft-backups
```

**Update backup script**:
```bash
# Backup creative world
echo "Backing up creative world..."
mkdir -p "/backups/creative/daily/$BACKUP_DATE"
rsync -av --delete /data/creative/ "/backups/creative/daily/$BACKUP_DATE/"
echo "Creative backup completed"

# Cleanup old backups (keep last 7 for each world)
echo "Cleaning up old creative backups (keeping last 7)..."
cd /backups/creative/daily && ls -1t | tail -n +8 | xargs -r rm -rf
```

**Apply changes**:
```bash
kubectl apply -f backup/cronjob.yaml
```

### 7. Test Connection

Connect from your Minecraft client:

1. Open Minecraft Java Edition
2. Go to Multiplayer
3. Add Server
4. **Server Address**: `creative.cliff.li:25565` (or just `creative.cliff.li`)
5. Click "Done" and join the server

If connection fails, check troubleshooting section below.

## Server Type Examples

### Modded Server (Fabric)

```yaml
minecraftServer:
  eula: true
  version: "1.20.1"
  type: "FABRIC"

  modrinth:
    projects:
      - fabric-api
      - lithium
      - ferrite-core
      - carpet
      - carpet-extra

  mode: survival
  difficulty: hard
  serviceType: ClusterIP

serviceAnnotations:
  mc-router.itzg.me/externalServerName: "modded.cliff.li"
```

### Skyblock Server (Paper + Plugins)

```yaml
minecraftServer:
  eula: true
  version: "1.20.4"
  type: "PAPER"

  mode: survival
  difficulty: normal
  serviceType: ClusterIP

  # Download Skyblock plugin
  downloadModpackZip: "https://example.com/skyblock-plugin.zip"

serviceAnnotations:
  mc-router.itzg.me/externalServerName: "skyblock.cliff.li"
```

### Snapshot/Testing Server

```yaml
minecraftServer:
  eula: true
  version: "SNAPSHOT"
  type: "VANILLA"

  mode: creative
  difficulty: peaceful
  serviceType: ClusterIP

serviceAnnotations:
  mc-router.itzg.me/externalServerName: "snapshot.cliff.li"
```

## Storage Considerations

### Local Storage (Recommended)

**Pros**:
- Fast chunk loading/saving
- No network overhead
- Best performance

**Cons**:
- Pod must stay on same node
- Requires node affinity configuration

**Configuration**:
```yaml
persistence:
  storageClass: local-path
  dataDir:
    enabled: true
    Size: 50Gi

nodeSelector:
  kubernetes.io/hostname: cyl-mitx

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cyl-mitx
```

### NFS Storage

**Pros**:
- Pod can run on any node
- Automatic backups easier
- No node affinity needed

**Cons**:
- Slower chunk loading
- Network overhead
- Potential lag spikes

**Configuration**:
```yaml
persistence:
  storageClass: nfs-direct
  dataDir:
    enabled: true
    Size: 50Gi

# No nodeSelector or affinity needed
```

## Backup Configuration

### NFS Backups (Recommended)

Add backup storage and CronJob similar to the main server:

**`backup-storage.yaml`**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minecraft-creative-backups
  namespace: games
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-direct
  resources:
    requests:
      storage: 100Gi
```

**`backup-cronjob.yaml`**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: minecraft-creative-backup
  namespace: games
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: alpine:latest
            command:
            - /bin/sh
            - -c
            - |
              apk add --no-cache rsync
              BACKUP_DIR="/backups/daily/$(date +%Y%m%d-%H%M%S)"
              mkdir -p "$BACKUP_DIR"
              rsync -av --delete /data/ "$BACKUP_DIR/"
              # Keep last 7 days
              find /backups/daily -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;
            volumeMounts:
            - name: data
              mountPath: /data
              readOnly: true
            - name: backups
              mountPath: /backups
          volumes:
          - name: data
            persistentVolumeClaim:
              claimName: minecraft-creative-minecraft-datadir
          - name: backups
            persistentVolumeClaim:
              claimName: minecraft-creative-backups
          restartPolicy: OnFailure
          nodeSelector:
            kubernetes.io/hostname: cyl-mitx  # Only if using local-path storage
```

Deploy backups:
```bash
kubectl apply -f backup-storage.yaml
kubectl apply -f backup-cronjob.yaml
```

## Managing Multiple Servers

### List All Minecraft Servers

```bash
# Get all Minecraft pods
kubectl get pods -n games -l app.kubernetes.io/name=minecraft

# Get all services
kubectl get svc -n games | grep minecraft
```

### View Resource Usage

```bash
# CPU and memory usage
kubectl top pods -n games -l app.kubernetes.io/name=minecraft

# Storage usage
kubectl exec -n games <pod-name> -- df -h /data
```

### Update Server Configuration

```bash
# Edit values file
vim worlds/<servername>-values.yaml

# Apply changes
helm upgrade minecraft-<servername> itzg/minecraft -n games \
  -f worlds/<servername>-values.yaml
```

### Delete a Server

```bash
# Delete Helm release
helm uninstall minecraft-<servername> -n games

# Delete PVCs (data will be lost!)
kubectl delete pvc -n games minecraft-<servername>-datadir

# Remove from backup CronJob
vim backup/cronjob.yaml  # Remove volume mounts and volumes

# Remove DNS record from DNS provider
```

## Troubleshooting

### Server Not Discovered by mc-router

**Check the Service annotation** — discovery keys off the *Service*, not the pod:
```bash
kubectl get svc -n games -o custom-columns=\
'NAME:.metadata.name,ROUTE:.metadata.annotations.mc-router\.itzg\.me/externalServerName'
```

Ensure the annotation is present:
```yaml
metadata:
  annotations:
    mc-router.itzg.me/externalServerName: "yourserver.mc.cliff.li"
```

**Check mc-router logs**:
```bash
kubectl logs -n games deployment/mc-router | grep yourserver
```

### Connection Refused

**Check server is running**:
```bash
kubectl get pods -n games -l app=minecraft-<servername>
```

**Test internal connectivity**:
```bash
kubectl exec -n games deployment/mc-router -- nc -zv minecraft-<servername>-minecraft 25565
```

**Check DNS resolution**:
```bash
nslookup yourserver.cliff.li
```

### Server Crashes on Start

**Check logs**:
```bash
kubectl logs -n games -l app=minecraft-<servername> --tail=100
```

Common issues:
- Out of memory (increase `memory` in values.yaml)
- Invalid mod combination (check mod compatibility)
- Corrupted world (delete PVC and restart)

### Slow Performance

**Check resource usage**:
```bash
kubectl top pods -n games -l app=minecraft-<servername>
```

**Solutions**:
- Increase CPU/memory requests
- Reduce view distance
- Add performance mods (Lithium, Ferrite Core)
- Use local-path storage instead of NFS

## Best Practices

1. **Naming Convention**: Use consistent naming like `minecraft-<type>` (minecraft-creative, minecraft-survival, etc.)
2. **Resource Limits**: Set appropriate CPU/memory based on expected players
3. **Backups**: Always configure NFS backups with CronJob
4. **Monitoring**: Add Prometheus scraping for server metrics
5. **Documentation**: Update server README with specific configuration notes
6. **Version Pinning**: Pin specific Minecraft versions instead of "LATEST" for stability

## Quick Reference

### Add Server Checklist

- [ ] Create `worlds/<servername>-values.yaml`
- [ ] Configure server (type, mode, MOTD, mc-router annotation)
- [ ] Deploy with `helm install`
- [ ] Verify pod is running
- [ ] Check mc-router discovered server
- [ ] Add DNS A record for `<servername>.mc.cliff.li`
- [ ] Wait for DNS propagation
- [ ] Update `backup/cronjob.yaml` to include new world
- [ ] Apply backup CronJob changes
- [ ] Test connection from Minecraft client
- [ ] Update main README.md with server info

### Useful Commands

```bash
# Port forward to server (for testing)
kubectl port-forward -n games svc/minecraft-<servername>-minecraft 25565:25565

# Access server console
kubectl exec -n games deployment/minecraft-<servername>-minecraft -- rcon-cli

# View server logs
kubectl logs -n games -l app=minecraft-<servername> -f

# Check mc-router routes
kubectl port-forward -n games svc/mc-router 8080:8080
curl http://localhost:8080/routes | jq

# Restart server
kubectl rollout restart deployment/minecraft-<servername>-minecraft -n games
```

## Additional Resources

- [itzg/minecraft-server Chart Documentation](https://github.com/itzg/minecraft-server-charts)
- [Minecraft Server Properties Reference](https://minecraft.wiki/w/Server.properties)
- [mc-router GitHub](https://github.com/itzg/mc-router)
- mc-router setup in this repo: `README.md` (same directory)
