# Minecraft Servers

Kubernetes deployment of multiple Minecraft Java Edition servers with automatic domain-based routing.

## Overview

This directory contains all Minecraft-related infrastructure for the homelab:

- **Multiple Minecraft Worlds**: Currently running Cobblestone, Sandstone, and Apricorn servers
- **mc-router**: Reverse proxy for domain-based routing to multiple servers
- **Unified Backup System**: Single CronJob backing up all worlds to NFS
- **Auto-Discovery**: New servers automatically discovered and routed

## Directory Structure

```
minecraft/
├── worlds/              # Individual world configurations
│   ├── cobblestone-values.yaml
│   ├── sandstone-values.yaml
│   └── apricorn-values.yaml
├── mc-router/           # Routing infrastructure
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── rbac.yaml
│   └── docs/           # mc-router documentation
├── backup/              # Backup configuration
│   ├── cronjob.yaml    # Daily backups for all worlds
│   └── storage.yaml    # NFS backup storage
└── README.md           # This file
```

## Active Servers

| Server | Domain | MOTD | Type | Node | State (2026-08-21) |
|--------|--------|------|------|------|--------------------|
| Cobblestone | cobblestone.mc.cliff.li | Cliff's Magical World | Fabric (Latest) | cyl-mitx | running (1/1) |
| Sandstone | sandstone.mc.cliff.li | it gets everywhere | Fabric (Latest) | cyl-mitx | **scaled to 0** |
| Apricorn | apricorn.mc.cliff.li | Cobblemon Adventures | Fabric (Latest) + Cobblemon | cyl-mitx | **scaled to 0** |

Sandstone and Apricorn are idled — their Helm releases, PVCs and services still
exist, only the pods are stopped. The idle state is pinned as `replicaCount: 0`
in each world's values file, **not** by a manual `kubectl scale`: the chart
defaults to `replicaCount: 1`, so an unpinned world silently restarts on the
next `helm upgrade`.

To bring a world back, set `replicaCount: 1` in its values file and upgrade —
this keeps the repo authoritative:

```bash
helm upgrade minecraft-sandstone itzg/minecraft -n games \
  -f worlds/sandstone-values.yaml
```

The backup CronJob covers all three worlds regardless of whether they're
running.

## Architecture

### Connection Flow

```
Player Client
    ↓
minecraft.cliff.li:25565
    ↓
Internet → VPS (217.154.249.14)
    ↓
Nginx TCP Proxy
    ↓
Tailscale VPN
    ↓
Traefik (homelab)
    ↓
mc-router (domain-based routing)
    ├─→ cobblestone.mc.cliff.li → Cobblestone Server
    ├─→ sandstone.mc.cliff.li → Sandstone Server
    └─→ apricorn.mc.cliff.li → Apricorn Server (Cobblemon)
```

### Components

- **Helm Chart**: [itzg/minecraft](https://github.com/itzg/minecraft-server-charts)
- **Routing**: mc-router with Kubernetes auto-discovery
- **Storage**: Local SSD (local-path) on cyl-mitx node
- **Backups**: NFS storage with daily automated backups
- **Resources**: 1 CPU core, 2Gi memory per server (no limits)

## Quick Start

### Prerequisites

```bash
# Add Helm repository
helm repo add itzg https://itzg.github.io/minecraft-server-charts/
helm repo update

# Create namespace
kubectl create namespace games
```

### Deploy Infrastructure

1. **Deploy mc-router** (if not already deployed):
   ```bash
   kubectl apply -f mc-router/rbac.yaml
   kubectl apply -f mc-router/deployment.yaml
   kubectl apply -f mc-router/service.yaml
   ```

2. **Create backup storage**:
   ```bash
   kubectl apply -f backup/storage.yaml
   ```

3. **Deploy Minecraft servers**:
   ```bash
   # Cobblestone
   helm install minecraft-cobblestone itzg/minecraft -n games \
     -f worlds/cobblestone-values.yaml

   # Sandstone
   helm install minecraft-sandstone itzg/minecraft -n games \
     -f worlds/sandstone-values.yaml

   # Apricorn (Cobblemon)
   helm install minecraft-apricorn itzg/minecraft -n games \
     -f worlds/apricorn-values.yaml
   ```

4. **Deploy backup CronJob**:
   ```bash
   kubectl apply -f backup/cronjob.yaml
   ```

### Verify Deployment

```bash
# Check pods
kubectl get pods -n games

# Check mc-router discovered both servers
kubectl port-forward -n games deployment/mc-router 8080:8080 &
curl http://localhost:8080/routes | jq
```

Expected output:
```json
{
  "cobblestone.mc.cliff.li": "10.43.x.x:25565",
  "sandstone.mc.cliff.li": "10.43.y.y:25565",
  "apricorn.mc.cliff.li": "10.43.z.z:25565"
}
```

## Adding New Servers

**See**: `mc-router/docs/ADDING-SERVERS.md` for detailed instructions.

**Quick steps**:

1. Create new values file in `worlds/`:
   ```bash
   cp worlds/cobblestone-values.yaml worlds/newworld-values.yaml
   ```

2. Update configuration:
   ```yaml
   serviceAnnotations:
     mc-router.itzg.me/externalServerName: "newworld.mc.cliff.li"

   minecraftServer:
     motd: "My New World"
     # ... other settings
   ```

3. Deploy:
   ```bash
   helm install minecraft-newworld itzg/minecraft -n games \
     -f worlds/newworld-values.yaml
   ```

4. Add DNS record: `newworld.mc.cliff.li → VPS_IP`

5. Update `backup/cronjob.yaml` to include new world

mc-router automatically discovers and routes to the new server within seconds!

## Management

### View Server Logs

```bash
# Cobblestone
kubectl logs -n games -l app=minecraft-cobblestone -f

# Sandstone
kubectl logs -n games -l app=minecraft-sandstone -f

# Apricorn
kubectl logs -n games -l app=minecraft-apricorn -f
```

### Access Server Console

```bash
# Cobblestone
kubectl exec -n games deployment/minecraft-cobblestone -it -- rcon-cli

# Sandstone
kubectl exec -n games deployment/minecraft-sandstone -it -- rcon-cli

# Apricorn
kubectl exec -n games deployment/minecraft-apricorn -it -- rcon-cli
```

### Check Resource Usage

```bash
kubectl top pods -n games | grep minecraft
```

### Manual Backup

```bash
kubectl create job -n games --from=cronjob/minecraft-backup minecraft-backup-manual-$(date +%s)
```

### Upgrade Server

```bash
# Edit worlds configuration
vim worlds/cobblestone-values.yaml

# Apply changes
helm upgrade minecraft-cobblestone itzg/minecraft -n games \
  -f worlds/cobblestone-values.yaml
```

## Backup System

- **Schedule**: `0 0 * * *` — daily at midnight UTC
- **Storage**: NFS PV on `192.168.1.94`, path `/media/games` (StorageClass
  `nfs-direct`), mounted at `/backups` in the job
- **Worlds covered**: all three (cobblestone, sandstone, apricorn) — including
  the two currently scaled to 0
- **Retention**: last 7 daily backups per world; a daily that ages out is
  **promoted to `weekly/`** if it is 7+ days newer than the newest existing
  weekly, otherwise deleted
- **Method**: rsync via Kubernetes CronJob (3 successful jobs kept in history)

**Backup structure**:
```
/backups/
├── cobblestone/
│   ├── daily/20251231-000000/ …   (last 7)
│   └── weekly/20251215-000000/ …  (promoted)
├── sandstone/
│   ├── daily/ …
│   └── weekly/ …
└── apricorn/
    ├── daily/ …
    └── weekly/ …
```

### Restore from Backup

1. **Scale server to 0**:
   ```bash
   kubectl scale deployment -n games minecraft-cobblestone --replicas=0
   ```

2. **Find PVC path** on cyl-mitx node:
   ```bash
   kubectl get pv -o custom-columns=NAME:.metadata.name,PATH:.spec.local.path | grep cobblestone
   ```

3. **Restore data** (from cyl-mitx node):
   ```bash
   rsync -av /path/to/nfs/backups/cobblestone/daily/<backup-date>/ /path/to/local-pvc/
   ```

4. **Scale server back up**:
   ```bash
   kubectl scale deployment -n games minecraft-cobblestone --replicas=1
   ```

## Monitoring

### mc-router Routes

```bash
kubectl port-forward -n games deployment/mc-router 8080:8080
curl http://localhost:8080/routes
```

### mc-router Logs

```bash
kubectl logs -n games deployment/mc-router -f
```

### Backup Status

```bash
# View CronJob schedule
kubectl get cronjob -n games minecraft-backup

# View recent backup jobs
kubectl get jobs -n games | grep minecraft-backup

# Check backup logs
kubectl logs -n games job/minecraft-backup-<job-id>
```

## Troubleshooting

### Server Not Responding

1. **Check pod status**:
   ```bash
   kubectl get pods -n games | grep minecraft
   ```

2. **Check logs for errors**:
   ```bash
   kubectl logs -n games <pod-name> --tail=100
   ```

3. **Verify mc-router discovery**:
   ```bash
   kubectl port-forward -n games deployment/mc-router 8080:8080
   curl http://localhost:8080/routes | grep <server-name>
   ```

### Connection Timeout

1. **Test DNS resolution**:
   ```bash
   nslookup cobblestone.mc.cliff.li
   ```

2. **Check Traefik routes**:
   ```bash
   kubectl get ingressroutetcp -n games
   ```

3. **Verify mc-router is running**:
   ```bash
   kubectl get pods -n games -l app=mc-router
   ```

### Backup Failures

1. **Check CronJob status**:
   ```bash
   kubectl get cronjob -n games minecraft-backup
   ```

2. **View failed job logs**:
   ```bash
   kubectl logs -n games job/minecraft-backup-<failed-job-id>
   ```

3. **Verify NFS mount**:
   ```bash
   kubectl exec -n games deployment/minecraft-cobblestone -- df -h /backups
   ```

## Performance Optimization

### Recommended Mods

Both servers include performance mods:
- **Lithium**: Server-side optimization
- **Ferrite Core**: Memory usage reduction

### Resource Tuning

Edit `worlds/<server>-values.yaml`:

```yaml
# Increase memory for more players
minecraftServer:
  memory: 6G  # Default: 4G

# Adjust view distance
minecraftServer:
  viewDistance: 12  # Default: 10

# Increase CPU allocation
resources:
  requests:
    cpu: 2000m  # Default: 1000m
    memory: 4Gi  # Default: 2Gi
```

Then upgrade:
```bash
helm upgrade minecraft-<servername> itzg/minecraft -n games \
  -f worlds/<server>-values.yaml
```

## Documentation

- **mc-router Setup**: `mc-router/docs/README.md`
- **Adding Servers**: `mc-router/docs/ADDING-SERVERS.md`

## External Resources

- [itzg/minecraft-server Chart](https://github.com/itzg/minecraft-server-charts)
- [mc-router GitHub](https://github.com/itzg/mc-router)
- [Minecraft Wiki](https://minecraft.wiki/)
