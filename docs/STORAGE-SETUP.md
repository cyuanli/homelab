# Manual SnapRAID + MergerFS Setup Guide

**⚠️ CRITICAL: This process involves formatting drives and modifying system configuration. Take your time and double-check every step.**

## Prerequisites

1. **Multiple HDDs** - at least 2 drives (1 for data, 1 for parity)
2. **Root access** - all commands require sudo
3. **Time** - initial sync can take hours for large drives
4. **Backup** - any important data should be backed up elsewhere

## Overview

We'll create:
- **Individual mounts** at `/mnt/data1`, `/mnt/data2`, etc.
- **Parity drive** at `/mnt/parity1` 
- **Unified pool** at `/media/data` (via MergerFS)
- **Automated protection** via SnapRAID

---

## Step 1: Identify Your Drives

### List all drives
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
```

### Check what's mounted
```bash
df -h
mount | grep "^/dev/sd"
```

### Identify drives to use
- **Note the drive names** (e.g., `/dev/sdb`, `/dev/sdc`)
- **Check current filesystems** - we need ext4 for data drives, will format parity as XFS
- **Verify sizes** - parity drive should be ≥ largest data drive

**⚠️ Write down your drive plan:**
```
Parity drive: /dev/sd_ (___GB) - will be WIPED
Data drive 1: /dev/sd_ (___GB) - preserve data? Y/N
Data drive 2: /dev/sd_ (___GB) - preserve data? Y/N  
Data drive 3: /dev/sd_ (___GB) - preserve data? Y/N
```

---

## Step 2: Install Required Packages

```bash
sudo apt update
sudo apt install -y mergerfs snapraid xfsprogs parted e2fsprogs
```

Verify installation:
```bash
which snapraid mergerfs mkfs.xfs
```

---

## Step 3: Prepare Drives

### For Each Drive That Needs Formatting:

⚠️ **This destroys all data on the drive!**

```bash
# Replace /dev/sdX with your actual drive
DRIVE=/dev/sdX

# Wipe partition table
sudo sgdisk --zap-all $DRIVE

# Create new GPT table and partition
sudo parted -s $DRIVE mklabel gpt
sudo parted -s $DRIVE mkpart primary 2048s 100%

# Format the partition
# For PARITY drive (XFS):
sudo mkfs.xfs -f -L parity1 ${DRIVE}1

# For DATA drives (ext4):
sudo mkfs.ext4 -F -L data1 ${DRIVE}1
```

### For Drives with Existing Data (ext4 only):

Check filesystem first:
```bash
lsblk -f /dev/sdX1
```

If it shows `ext4`, you can preserve data:
```bash
# Just set a label for organization
sudo e2label /dev/sdX1 data1
```

---

## Step 4: Create Mount Points

```bash
# Create mount points for all drives
sudo mkdir -p /mnt/parity1
sudo mkdir -p /mnt/data1 /mnt/data2 /mnt/data3  # Adjust for your drive count
sudo mkdir -p /media/data
```

---

## Step 5: Configure fstab

### Get UUIDs for all drives:
```bash
sudo blkid | grep -E "(parity|data)"
```

### Edit fstab:
```bash
sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
sudo nano /etc/fstab
```

### Add these lines (replace UUIDs with yours):
```bash
# Root filesystem
UUID=your-root-uuid / ext4 defaults 0 1

# SnapRAID + MergerFS Storage Pool
# Added on YYYY-MM-DD

# Parity drive (XFS)
UUID=your-parity-uuid /mnt/parity1 xfs defaults,noatime 0 2

# Data drives (ext4)
UUID=your-data1-uuid /mnt/data1 ext4 defaults,noatime,nodiratime 0 2
UUID=your-data2-uuid /mnt/data2 ext4 defaults,noatime,nodiratime 0 2
UUID=your-data3-uuid /mnt/data3 ext4 defaults,noatime,nodiratime 0 2

# MergerFS unified pool
/mnt/data1:/mnt/data2:/mnt/data3 /media/data mergerfs defaults,noatime,direct_io,minfreespace=50G,category.create=epmfs,moveonenospc=true 0 0
```

### Test the configuration:
```bash
# Test mount (should show no errors)
sudo mount -a

# Verify all drives mounted
df -h | grep -E "(data|parity)"

# Check the unified pool
ls /media/data
df -h /media/data
```

---

## Step 6: Configure SnapRAID

### Create config file:
```bash
sudo nano /etc/snapraid.conf
```

### Add configuration:
```bash
# SnapRAID Configuration
# Generated on $(date)

# Parity drive location  
parity /mnt/parity1/snapraid.parity

# Content file locations (multiple copies for redundancy)
content /var/snapraid/snapraid.content
content /mnt/data1/snapraid.content
content /mnt/data2/snapraid.content
content /mnt/data3/snapraid.content

# Data drives
data d1 /mnt/data1
data d2 /mnt/data2  
data d3 /mnt/data3

# Exclusions (files to not protect)
exclude *.tmp
exclude *.temp
exclude *.log
exclude *.bak
exclude Thumbs.db
exclude .DS_Store
exclude .snapshots/
exclude lost+found/
exclude /tmp/
exclude .Trashes/

# Configuration
block_size 256
autosave 250
```

### Create content directory:
```bash
sudo mkdir -p /var/snapraid
```

---

## Step 7: Set Permissions

```bash
# Create a shared group for multi-service storage access
sudo groupadd storage

# Add common service users to the storage group
sudo usermod -a -G storage www-data    # Nextcloud/web services
sudo usermod -a -G storage $USER       # Your user account

# Set shared ownership and permissions
sudo chown -R $USER:storage /media/data
sudo chmod -R 775 /media/data

# Make sure new files inherit group permissions
sudo chmod g+s /media/data
```

**What this does:**
- Creates a `storage` group for shared access
- Allows your user account full access
- Allows www-data (Nextcloud) read/write access  
- Other services can be added to `storage` group later
- New files automatically get proper group permissions

**Adding other services later:**
```bash
# Example: Add another service user to storage group
sudo usermod -a -G storage service_user_name
```

---

## Step 8: Initial SnapRAID Sync

**⚠️ This can take hours for large drives!**

### Test configuration first:
```bash
sudo snapraid status
```
Should show your drives and no errors.

### Run the initial sync:
```bash
sudo snapraid sync
```

Monitor progress - it will show:
- Number of files processed
- GB processed  
- Estimated time remaining
- Any errors or warnings

---

## Step 9: Set Up Automated Maintenance

### Download snapraid-runner:
```bash
sudo curl -o /usr/local/bin/snapraid-runner https://raw.githubusercontent.com/Chronial/snapraid-runner/master/snapraid-runner.py
sudo chmod +x /usr/local/bin/snapraid-runner
```

### Create runner config:
```bash
sudo nano /etc/snapraid-runner.conf
```

```ini
[snapraid]
executable = /usr/bin/snapraid
config = /etc/snapraid.conf
deletethreshold = 40
touchthreshold = 500

[logging]
file = /var/log/snapraid.log
maxsize = 5000

[email]
sendemail = false

[scrub]
enabled = true  
percentage = 5
older-than = 10
```

### Add cron job:
```bash
sudo crontab -e
```

Add this line for daily 2 AM sync:
```bash
0 2 * * * /usr/local/bin/snapraid-runner
```

### Create log file:
```bash
sudo touch /var/log/snapraid.log
```

### Optional: Set up Discord notifications for failures:
```bash
# Create notification script
sudo tee /usr/local/bin/snapraid-notify << 'EOF'
#!/bin/bash

WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL_HERE"
LOG_FILE="/var/log/snapraid.log"

# Get last few lines of log to check status
LAST_LINES=$(tail -20 "$LOG_FILE")

# Check if sync failed
if echo "$LAST_LINES" | grep -q "FAILED\|ERROR\|DANGER"; then
    # Extract error details
    ERROR_MSG=$(echo "$LAST_LINES" | grep -E "FAILED|ERROR|DANGER" | tail -5)
    
    # Send Discord notification
    curl -H "Content-Type: application/json" \
         -d "{\"content\": \"🚨 **SnapRAID FAILED on $(hostname)**\n\`\`\`\n$ERROR_MSG\n\`\`\`\"}" \
         "$WEBHOOK_URL"
fi
EOF

sudo chmod +x /usr/local/bin/snapraid-notify
```

Update the cron job to include notifications:
```bash
0 2 * * * /usr/local/bin/snapraid-runner && /usr/local/bin/snapraid-notify
```

---

## Step 10: Verification

### Check everything is working:
```bash
# Verify mounts
df -h | grep -E "(data|parity|media)"

# Check SnapRAID status
sudo snapraid status

# Test writing a file
echo "test" | sudo tee /media/data/test.txt
ls -la /media/data/

# Check which drive it went to
find /mnt/data* -name "test.txt" -ls
```

### Final status check:
```bash
# Storage overview
echo "=== Storage Overview ==="
df -h /media/data
echo ""
echo "=== Drive Status ==="  
sudo snapraid status
echo ""
echo "=== Recent Sync Log ==="
tail -10 /var/log/snapraid.log 2>/dev/null || echo "No sync log yet"
```

---

## Daily Operations

### Check status:
```bash
sudo snapraid status
sudo snapraid diff  # Shows changes since last sync
df -h /media/data   # Available space
```

### Manual sync (if needed):
```bash
sudo snapraid sync
```

### Check logs:
```bash
tail -f /var/log/snapraid.log
```

---

## Troubleshooting

### "Drive not found" errors:
```bash
# Check if drives are mounted
mount | grep data
# Check UUIDs haven't changed  
sudo blkid
```

### "Too many deleted files":
```bash
# Review what changed
sudo snapraid diff
# Force sync if safe
sudo snapraid sync -h
```

### Performance issues:
```bash
# Check drive health
sudo smartctl -a /dev/sdX
# Monitor during sync
iostat -x 1
```

### Recovery from drive failure:
```bash
# Replace failed drive, format as ext4, mount in same location
# Then restore:
sudo snapraid fix -d d1  # Replace d1 with failed drive name
```

---

## Adding Drives Later

### To add a new data drive:
1. Format as ext4, add to `/etc/fstab`
2. Add to `/etc/snapraid.conf` as new data drive
3. Update MergerFS line in fstab to include new mount
4. Remount and sync: `sudo mount -a && sudo snapraid sync`

---

---

## Step 11: Disk Health Monitoring & Failure Protection

**⚠️ CRITICAL: Without monitoring, services will continue writing to failed drives before you notice, potentially causing unrecoverable data loss!**

### Automatic Setup (Recommended)

If you're using the bootstrap setup script, disk monitoring is configured automatically:

```bash
# Run the main setup script - it will detect SnapRAID and configure monitoring
sudo ./scripts/setup.sh
```

The setup script will:
- Detect SnapRAID configuration automatically
- Install required monitoring tools
- Create Discord webhook configuration template
- Set up automated health checks every 5 minutes
- Test the monitoring system

### Manual Setup

If you need to set up monitoring manually:

#### Install Monitoring Tools:
```bash
# Already installed by setup script, but if needed:
sudo apt install -y smartmontools curl
```

#### Configure Discord Alerts:
```bash
# Copy the configuration template
cp scripts/disk-monitor.conf.example scripts/disk-monitor.conf

# Edit with your Discord webhook URL
nano scripts/disk-monitor.conf
```

Add your Discord webhook URL:
```bash
# Get webhook from Discord: Server Settings > Integrations > Webhooks
DISK_MONITOR_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_TOKEN"
```

#### Setup Automated Monitoring:
```bash
# Add to root crontab (monitoring needs root permissions)
sudo crontab -e

# Add this line for monitoring every 5 minutes:
*/5 * * * * /home/cyl/homelab/home-pc/scripts/disk-monitor-cron.sh >/dev/null 2>&1
```

### How It Works

**🔍 Continuous Monitoring:**
- Checks SMART health data every 5 minutes
- Monitors mount point accessibility 
- Tests write capability to all drives
- Detects filesystem errors in system logs

**🚨 Immediate Response on ANY Drive Failure:**
1. **Stops ALL Docker containers** - Prevents new writes
2. **Unmounts MergerFS pool** - Disables unified storage access
3. **Remounts ALL drives as read-only** - Complete write protection
4. **Exports Prometheus metrics** - Status exported for alerting

**📊 Metric Types:**
- 🚨 **Drive Health** - SMART failures, mount issues, filesystem errors
- 💾 **MergerFS Status** - Pool availability monitoring
- 📈 **Timestamp Tracking** - Last run and recovery states

### Testing the System

**Check Current Status:**
```bash
sudo scripts/disk-monitor.sh status
```

**View Prometheus Metrics:**
```bash
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom
```

**Note:** Alerts are sent via Prometheus/Alertmanager, not directly from scripts.

**View Monitoring Logs:**
```bash
sudo tail -f /var/log/disk-monitor.log
```

### Recovery Process

When you receive a disk failure alert:

1. **Investigate the failed drive(s)** mentioned in the alert
2. **Replace any failed hardware**
3. **Run SnapRAID sync** to rebuild protection:
   ```bash
   sudo snapraid sync
   ```
4. **Restore system operation:**
   ```bash
   # Remount drives as read-write
   sudo mount -o remount,rw /mnt/data1
   sudo mount -o remount,rw /mnt/data2
   sudo mount -o remount,rw /mnt/data3
   sudo mount -o remount,rw /mnt/data4
   sudo mount -o remount,rw /mnt/parity1
   
   # Remount MergerFS pool
   sudo mount /media/data
   
   # Restart Docker containers
   sudo docker start $(sudo docker ps -a -q)
   ```

### Monitoring System Files

The monitoring system consists of:

- **`scripts/disk-monitor.sh`** - Main monitoring script
- **`scripts/disk-monitor-cron.sh`** - Cron wrapper with webhook config loading
- **`scripts/disk-monitor.conf`** - Discord webhook configuration  
- **`scripts/disk-monitor.conf.example`** - Configuration template

**⚠️ Important Notes:**
- Monitoring runs as root (required for SMART access and service control)
- False positives trigger protection (better safe than sorry)
- No recovery automation (requires manual verification for safety)
- Monitors ALL drives in SnapRAID config (data + parity)

---

**🎯 Result**: You now have a unified `/media/data` directory with all your drives pooled together, protected by SnapRAID parity, AND continuously monitored for failures!

Your Nextcloud (and other services) can use `/media/data/nextcloud` for multi-terabyte storage with redundancy protection and automatic failure detection.

---

## Step 12: NFS Server Setup for K3s Cluster Storage

**Purpose:** Enable Kubernetes pods to access the SnapRAID+MergerFS storage from any node in the cluster, not just the storage node.

### Why NFS for K3s?

Without NFS, Kubernetes PersistentVolumes using `hostPath` can only be accessed from the node where the storage physically exists. This means all pods needing storage get pinned to that one node, causing:
- Memory pressure on the storage node
- Inefficient cluster resource utilization
- Single point of failure

With NFS CSI driver, pods can run on any node while accessing centralized storage over the network.

### Automatic Setup (Recommended)

The setup script handles NFS server and client installation automatically:

```bash
# Run on the storage node (e.g., cyl-homelab)
./scripts/setup-nfs-storage.sh
```

This script will:
- Install NFS kernel server (on storage nodes only)
- Configure NFS exports with proper security settings
- Set up firewall rules for NFS traffic
- Install NFS client utilities (on all nodes)

### Manual Setup

If you need to set up NFS manually:

#### On the Storage Node (e.g., cyl-homelab):

**Install NFS Server:**
```bash
sudo apt update
sudo apt install -y nfs-kernel-server
sudo systemctl enable --now nfs-kernel-server
```

**Configure NFS Exports with Bind Mounts:**

Our NFS setup uses `/exports` as the NFSv4 root with bind mounts for each service. This allows us to expose specific subdirectories with unique filesystem IDs.

```bash
sudo nano /etc/exports
```

Add the following (adjust the network range to match your LAN):
```bash
# NFSv4 export root
/exports 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=0)

# Explicit subdirectory exports (bind mounts need explicit exports with fsid)
/exports/media 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=1)
/exports/configs 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=2)
/exports/immich 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=3)
/exports/nextcloud 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=4)
```

**Key export options explained:**
- `rw` - Read-write access
- `sync` - Write operations complete before acknowledging (safer)
- `no_subtree_check` - Better performance, safe for single filesystem exports
- `no_root_squash` - Preserve root permissions (needed for containers)
- `fsid=0` - NFSv4 pseudo-root (allows relative paths in mounts)
- `fsid=1,2,3...` - Unique filesystem IDs for each subdirectory export

**Set up bind mounts:**

Create the exports directory structure and bind mount your data:
```bash
# Create exports root
sudo mkdir -p /exports

# Create bind mount points
sudo mkdir -p /exports/media /exports/configs /exports/immich /exports/nextcloud

# Mount bind mounts
sudo mount --bind /media/data /exports/media
sudo mount --bind /media/data/k3s-configs /exports/configs
sudo mount --bind /media/data/immich /exports/immich
sudo mount --bind /media/data/nextcloud /exports/nextcloud
```

**Make bind mounts persistent:**

Add to `/etc/fstab` so they survive reboots:
```bash
sudo nano /etc/fstab
```

Add these lines:
```bash
# NFS bind mounts for K3s cluster
/media/data                /exports/media      none  bind  0  0
/media/data/k3s-configs    /exports/configs    none  bind  0  0
/media/data/immich         /exports/immich     none  bind  0  0
/media/data/nextcloud      /exports/nextcloud  none  bind  0  0
```

**Apply the exports:**
```bash
sudo exportfs -ra
sudo exportfs -v  # Verify
```

**Configure Firewall:**
```bash
# Allow NFS from your LAN
sudo ufw allow from 192.168.0.0/16 to any port 111 proto tcp comment 'NFS rpcbind'
sudo ufw allow from 192.168.0.0/16 to any port 111 proto udp comment 'NFS rpcbind'
sudo ufw allow from 192.168.0.0/16 to any port 2049 proto tcp comment 'NFS server'
sudo ufw allow from 192.168.0.0/16 to any port 2049 proto udp comment 'NFS server'
sudo ufw reload
```

#### On ALL K3s Nodes:

**Install NFS Client:**
```bash
sudo apt update
sudo apt install -y nfs-common
```

**Test NFS connectivity:**
```bash
# From a non-storage node
showmount -e 192.168.1.94  # Replace with your storage node IP

# Should show:
# Export list for 192.168.1.94:
# /media/data 192.168.1.0/24
```

### Deploy NFS CSI Driver to K3s

The NFS CSI driver provides Kubernetes-native storage management using NFS as the backend.

**Deploy infrastructure (automatically done by setup-cluster.sh):**
```bash
# Deploy NFS CSI driver
kubectl apply -f cluster/infrastructure/csi-driver-nfs/

# Wait for controller to be ready
kubectl wait --for=condition=Ready pod -l app=csi-nfs-controller -n kube-system --timeout=120s

# Deploy NFS StorageClass
kubectl apply -f cluster/infrastructure/storage/nfs-storageclass.yaml
```

**Verify deployment:**
```bash
# Check CSI driver pods
kubectl get pods -n kube-system | grep csi-nfs

# Check StorageClass
kubectl get storageclass nfs-media
```

### Create Media Storage PersistentVolumes

Static PV provisioning for media applications:

```bash
# Create PVs and PVCs for media stack
kubectl apply -f cluster/applications/media-stack/storage/media-pvs.yaml
kubectl apply -f cluster/applications/media-stack/storage/media-pvcs.yaml

# Verify all PVCs are bound
kubectl get pv,pvc -n media
```

**The media PVs include:**
- `media-movies` - 2Ti (ReadWriteMany)
- `media-tv` - 2Ti (ReadWriteMany)
- `media-music` - 500Gi (ReadWriteMany)
- `media-downloads` - 2Ti (ReadWriteMany)
- `jellyfin-config` - 10Gi (ReadWriteOnce)
- `jellyfin-cache` - 50Gi (ReadWriteOnce)
- `prowlarr-config` - 5Gi (ReadWriteOnce)
- `radarr-config` - 5Gi (ReadWriteOnce)
- `sonarr-config` - 5Gi (ReadWriteOnce)
- `qbittorrent-config` - 5Gi (ReadWriteOnce)

### Directory Structure on Storage Node

Ensure these directories exist on the storage node:

```bash
sudo mkdir -p /media/data/media/{movies,tv,music}
sudo mkdir -p /media/data/downloads
sudo mkdir -p /media/data/k3s-configs/media-stack/{jellyfin-config,jellyfin-cache}
sudo mkdir -p /media/data/k3s-configs/media-stack/{prowlarr-config,radarr-config,sonarr-config,qbittorrent-config}
```

### NFSv4 Path Considerations

**Important:** With `fsid=0` on `/exports`, it becomes the NFSv4 pseudo-root. All PV paths are relative to this root:

- Export root: `/exports` with `fsid=0`
- Subdirectory export: `/exports/immich` with `fsid=3`
- Physical path on server: `/media/data/immich/library` (via bind mount)
- Path in PV spec: `/immich/library` (relative to /exports)

**Why use bind mounts?**
- **Isolation**: Each service gets its own export with unique fsid
- **Flexibility**: Can remap physical paths without changing Kubernetes configs
- **Organization**: Clean namespace under `/exports` for NFS clients
- **Compatibility**: Works around NFSv4 crossing filesystem boundaries

**Example PV configuration:**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-library
spec:
  capacity:
    storage: 5Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-media
  mountOptions:
    - nfsvers=4.1
    - hard
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: immich-library
    volumeAttributes:
      server: 192.168.1.94
      share: /immich/library  # Relative to /exports root
```

### Adding New Services to NFS

When you need to add a new service (like we did with Nextcloud), follow these steps:

**1. Create the data directory on the storage node:**
```bash
sudo mkdir -p /media/data/myservice
sudo chown -R appropriate_user:appropriate_group /media/data/myservice
```

**2. Create bind mount point:**
```bash
sudo mkdir -p /exports/myservice
```

**3. Create the bind mount:**
```bash
sudo mount --bind /media/data/myservice /exports/myservice
```

**4. Make it persistent in `/etc/fstab`:**
```bash
echo "/media/data/myservice /exports/myservice none bind 0 0" | sudo tee -a /etc/fstab
```

**5. Add export to `/etc/exports`:**
```bash
sudo nano /etc/exports
```
Add a new line with the next available fsid:
```bash
/exports/myservice 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=5)
```

**6. Apply the new export:**
```bash
sudo exportfs -ra
sudo exportfs -v  # Verify it appears
```

**7. Update the tracked exports file in your repo:**
```bash
# Copy to version control
sudo cp /etc/exports config/system-configs/exports
git add config/system-configs/exports
```

**8. Create Kubernetes PV and PVC:**
Create `storage-pvs.yaml` and `storage-pvcs.yaml` for your service:
```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: myservice-data
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-media
  mountOptions:
    - nfsvers=4.1
    - hard
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: myservice-data
    volumeAttributes:
      server: 192.168.1.94
      share: /myservice  # Relative to /exports
```

**Example: Nextcloud Migration**

When we migrated Nextcloud from hostPath to NFS, we:
1. Created bind mount: `/media/data/nextcloud` → `/exports/nextcloud`
2. Added export with `fsid=4`
3. Created PV pointing to `/nextcloud` (shares the physical `/media/data/nextcloud` via bind mount)
4. Changed deployment from `hostPath` to `persistentVolumeClaim`
5. Removed node affinity constraint (pod can now run on any node)

### Troubleshooting

**Mount timeouts:**
```bash
# Ensure nfs-common is installed on all nodes
kubectl get nodes -o wide
# SSH to each node and verify:
dpkg -l | grep nfs-common
```

**Permission denied:**
```bash
# Verify no_root_squash is set
sudo exportfs -v | grep media/data

# Check directory permissions on storage node
ls -la /media/data
```

**Stale file handle errors:**
```bash
# On storage node, unexport and re-export
sudo exportfs -ua
sudo exportfs -ra
```

**Connection refused:**
```bash
# Check firewall on storage node
sudo ufw status | grep -E "(111|2049)"

# Test connectivity from worker node
telnet 192.168.1.94 2049
```

### Integration with Media Services

After NFS setup, media services (Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent) can:
- Run on ANY cluster node (not pinned to storage node)
- Access shared media libraries via NFS
- Use persistent configs stored on NFS
- Distribute load across cluster

**Deploy media stack:**
```bash
./scripts/deploy-applications.sh media deploy
```

The deployment will automatically:
1. Create NFS-backed PVs and PVCs
2. Deploy all media services
3. Distribute pods across available nodes
4. Mount NFS volumes as needed

**Verify distributed deployment:**
```bash
kubectl get pods -n media -o wide
```

You should see pods running on different nodes, not all on the storage node.

---

**🎯 Result**: Your K3s cluster now has Kubernetes-native access to the SnapRAID+MergerFS storage pool. Pods can run on any node while accessing centralized storage, enabling efficient resource utilization and high availability!