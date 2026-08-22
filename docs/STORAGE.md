# Storage: SnapRAID + MergerFS

## Quick Reference

```
Data Drives (/mnt/data1..4)  →  MergerFS  →  /media/data (unified pool)
Parity Drive (/mnt/parity1)  →  SnapRAID  →  Data protection
                                    ↓
                              NFS Export  →  K8s PVs
```

- **MergerFS**: Combines multiple drives into single `/media/data` directory
- **SnapRAID**: Parity-based protection (can recover from 1 drive failure)
- **NFS**: Exports storage to all cluster nodes

### Daily Commands

```bash
sudo snapraid status       # Check status
df -h /media/data          # Available space
sudo snapraid sync         # Manual sync
sudo snapraid scrub        # Check integrity
```

### Key Files

- `/etc/fstab` - Mount configuration
- `/etc/snapraid.conf` - SnapRAID config
- `/etc/exports` - NFS exports

### Drive Failure Recovery

1. Replace failed drive
2. Format and mount to same location
3. Restore: `sudo snapraid fix -d <drive_name>`

### Monitoring

Disk health **and** the server-side NFS export layer are monitored via systemd
timer (every 5 min). Alerts via Prometheus/Alertmanager. See **Storage
durability → Layer 4** for the NFS export checks.

```bash
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom
cat /var/lib/node_exporter/textfile_collector/nfs_export.prom
./scripts/monitor-storage.sh status      # includes "=== NFS Export Layer ==="
journalctl -u disk-monitor.service -n 20
```

---

# Setup Guide

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

# MergerFS unified pool (4 data disks; noforget + inodecalc=path-hash keep NFS
# file handles valid across a remount — see "Storage durability" below)
/mnt/data1:/mnt/data2:/mnt/data3:/mnt/data4 /media/data mergerfs defaults,noatime,direct_io,minfreespace=51G,category.create=epmfs,moveonenospc=true,noforget,inodecalc=path-hash 0 0
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

### Setup systemd timer:
```bash
# Install systemd timer files from homelab config
sudo cp /home/cyl/homelab/config/systemd/snapraid-runner.{timer,service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now snapraid-runner.timer

# Verify it's scheduled
systemctl list-timers snapraid-runner.timer
```

### Create log file:
```bash
sudo touch /var/log/snapraid.log
```

### Failure notifications

No extra setup needed — `snapraid-runner.service` already chains the repo's
notify script:

```ini
ExecStart=/usr/local/bin/snapraid-runner -c /etc/snapraid-runner.conf
ExecStartPost=/home/cyl/homelab/scripts/snapraid-notify.sh
```

`scripts/snapraid-notify.sh` parses `/var/log/snapraid.log` and writes
Prometheus metrics to the node_exporter textfile collector; Alertmanager routes
them to Discord via the `alertmanager-discord` deployment in the `monitoring`
namespace. There is no standalone `/usr/local/bin/snapraid-notify` and no
webhook URL to configure here.

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

Disk monitoring is configured via Ansible:

```bash
cd ansible
ansible-playbook playbooks/packages.yml --ask-become-pass --limit cyl-homelab
ansible-playbook playbooks/systemd-timers.yml --ask-become-pass --limit cyl-homelab
```

This will:
- Install required monitoring tools
- Set up automated health checks every 5 minutes via systemd timer

### Manual Setup

If you need to set up monitoring manually:

#### Install Monitoring Tools:
```bash
# Already installed by setup script, but if needed:
sudo apt install -y smartmontools curl
```

#### Configure the drive map:
```bash
# Copy the configuration template (.conf is gitignored)
cp config/service-configs/monitoring.conf.template config/service-configs/monitoring.conf
nano config/service-configs/monitoring.conf
```

This file maps partitions to mount points and lists the physical drives to SMART
check. It contains **no webhook** — alerts leave the host as Prometheus metrics
in the node_exporter textfile collector and are routed to Discord by
Alertmanager. Keys and a warning about unstable `/dev/sdX` names are documented
in [Configuration](CONFIGURATION.md#monitoringconf); the current authoritative
device mapping is in
[`config/system-configs/DRIVE-MAPPING.md`](../config/system-configs/DRIVE-MAPPING.md).

#### Setup Automated Monitoring:
```bash
# Install systemd timer for disk monitoring (runs every 5 minutes)
sudo cp /home/cyl/homelab/config/systemd/disk-monitor.{timer,service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now disk-monitor.timer

# Verify it's running
systemctl list-timers disk-monitor.timer
journalctl -u disk-monitor.service -n 20
```

### How It Works

**🔍 Continuous Monitoring:**
- Checks SMART health data every 5 minutes
- Monitors mount point accessibility 
- Tests write capability to all drives
- Detects filesystem errors in system logs

**🚨 Immediate Response on ANY Drive Failure** (`lockdown_array()`), in order:
1. **Stops all Docker containers** - prevents new writes (skipped if no docker)
2. **Scales all deployments to 0 in the `media` and `cloud` namespaces** -
   note this does *not* cover `automation`, `games` or `location`, which also
   hold NFS-backed PVs
3. **Unmounts the MergerFS pool** - disables unified storage access
4. **Remounts ALL SnapRAID drives read-only** - complete write protection
5. **Exports Prometheus metrics** - status exported for alerting

The NFS export checks (Layer 4, below) are **advisory** and never trigger
lockdown.

**📊 Metric Types:**
- 🚨 **Drive Health** - SMART failures, mount issues, filesystem errors
- 💾 **MergerFS Status** - Pool availability monitoring
- 📈 **Timestamp Tracking** - Last run and recovery states

### Testing the System

**Check Current Status:**
```bash
./scripts/monitor-storage.sh status
```

**View Prometheus Metrics:**
```bash
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom
```

**Note:** Alerts are sent via Prometheus/Alertmanager, not directly from scripts.

**View Monitoring Logs:**
```bash
journalctl -u disk-monitor.service -f
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

- **`scripts/monitor-storage.sh`** - Main monitoring script
- **`config/service-configs/monitoring.conf`** - Drive configuration
- **`config/service-configs/monitoring.conf.template`** - Configuration template

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

NFS is configured via Ansible:

```bash
cd ansible
ansible-playbook playbooks/packages.yml --ask-become-pass --limit cyl-homelab
ansible-playbook playbooks/nfs-storage.yml --ask-become-pass --limit cyl-homelab
```

This will:
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
```

**Note:** We use a simplified structure where `/exports/media` contains all application data (immich, nextcloud, games, etc.) as subdirectories. This avoids redundant bind mounts and export entries.

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
sudo mkdir -p /exports/media /exports/configs

# Mount bind mounts
sudo mount --bind /media/data /exports/media
sudo mount --bind /srv/app-storage /exports/configs
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
/srv/app-storage           /exports/configs    none  bind  0  0
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

### Deploy NFS StorageClass to K3s

We use native Kubernetes NFS volumes (`spec.nfs`) instead of a CSI driver for simplicity and reliability.

**Deploy infrastructure (part of post-install bootstrapping, see INSTALLATION.md):**
```bash
# Deploy NFS direct StorageClass
kubectl apply -f cluster/infrastructure/storage/nfs-direct-storageclass.yaml
```

**Verify deployment:**
```bash
# Check StorageClass
kubectl get storageclass nfs-direct
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
sudo mkdir -p /srv/app-storage/media-stack/{jellyfin-config,jellyfin-cache}
sudo mkdir -p /srv/app-storage/media-stack/{prowlarr-config,radarr-config,sonarr-config,qbittorrent-config}
sudo mkdir -p /srv/app-storage/immich/{thumbs,encoded-video,profile}
```

### NFSv4 Path Considerations

**Important:** With `fsid=0` on `/exports`, it becomes the NFSv4 pseudo-root. All PV paths are relative to this root:

- Export root: `/exports` with `fsid=0`
- Subdirectory export: `/exports/media` with `fsid=1`
- Physical path on server: `/media/data/immich/library` (via bind mount to /exports/media)
- Path in PV spec: `/media/immich/library` (relative to /exports)

**Why use bind mounts?**
- **Simplicity**: Single `/exports/media` contains all application data as subdirectories
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
  storageClassName: nfs-direct
  mountOptions:
    - vers=4.1
    - hard
  nfs:
    server: 192.168.1.94
    path: /media/immich/library  # Relative to /exports root
```

### Adding New Services to NFS

When you need to add a new service, follow these simplified steps:

**1. Create the data directory on the storage node:**
```bash
sudo mkdir -p /media/data/myservice
sudo chown -R appropriate_user:appropriate_group /media/data/myservice
```

**2. Create Kubernetes PV and PVC:**
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
  storageClassName: nfs-direct
  mountOptions:
    - vers=4.1
    - hard
  nfs:
    server: 192.168.1.94
    path: /media/myservice  # Relative to /exports, accesses /media/data/myservice
```

> ⚠️ **NFSv4 pseudo-root path gotcha.** The `path:` is resolved **relative to the
> `fsid=0` pseudo-root (`/exports`)**, so it must be `/media/<x>` (→ physical
> `/exports/media/<x>` = `/media/data/<x>`). Do **not** write `/exports/media/<x>`
> — the server would resolve that to `/exports/exports/media/<x>` and the mount
> fails with `No such file or directory`. (This bit us while testing on
> 2026-08-21.) Correspondingly, `/media/data` on the host is exported to clients
> as `/media`, not `/media/data`.

**That's it!** No need to create additional bind mounts or export entries. The `/exports/media` bind mount already provides access to all subdirectories under `/media/data/`. Verified 2026-08-21: with only `fsid=0/1/2` exported (no dedicated `fsid=3`), a client mounting the plain `/media` export can read `nextcloud/` inside it — so Nextcloud needs no export of its own.

**Example: Nextcloud and Immich**

All services use the same simplified structure:
- Nextcloud: PV points to `/media/nextcloud` (physical: `/media/data/nextcloud`)
- Immich: PV points to `/media/immich/library` (physical: `/media/data/immich/library`)
- Games: PV would point to `/media/games` (physical: `/media/data/games`)

All are accessible through the single `/exports/media` export with `fsid=1`.

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

Usually caused by a mergerfs remount/restart: the pool gets a new mount, the
`/exports/media` bind still points at the old one, and NFS clients hold handles
to now-gone inodes. First refresh nfsd; if that doesn't clear it, re-point the
bind and refresh again:
```bash
# On storage node, unexport and re-export (refreshes nfsd)
sudo exportfs -ua
sudo exportfs -ra

# If still stale after a mergerfs remount, re-point the export bind at the pool:
sudo umount -l /exports/media
sudo mount --bind /media/data /exports/media
sudo exportfs -ra
```
The `noforget,inodecalc=path-hash` mergerfs options (see below) make handles
survive a remount, and `mergerfs-media.service` automates the rebind + refresh.
See **Storage durability** below for the permanent fix.

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

---

## Storage durability (mergerfs crash hardening)

**Background — the 2026-08-21 incident.** mergerfs (v2.40.2-5) segfaulted in a
read thread. Because the pool was mounted from `/etc/fstab`, nothing restarted
it: `/media/data` went `Transport endpoint is not connected` (ENOTCONN), the
`/exports/media` NFS export served broken handles, and every NFS-backed pod in
the cluster (Nextcloud, Jellyfin, qBittorrent, Immich, Home Assistant, …)
cascaded into failure. Recovery required a manual remount plus `exportfs` and a
round of pod restarts. Three independent weaknesses turned one crash into a
multi-hour outage; each layer below removes one.

### Layer 1 — Prevent the crash: keep mergerfs current
The segfault is a mergerfs bug. Newer releases fix crash classes in the FUSE
path, **auto-unmount a broken ENOTCONN mount on start** (2.42.0), and improve
inode stability across restarts (2.41.0). Install the project's own `.deb`
(recommended over the distro package):
```bash
# On the storage host. Check https://github.com/trapexit/mergerfs/releases for the current version.
mergerfs -V                             # currently 2.42.0 (was 2.40.2-5 before 2026-08-21)
curl -fsSLO https://github.com/trapexit/mergerfs/releases/download/2.42.0/mergerfs_2.42.0.debian-trixie_amd64.deb
sudo dpkg -i mergerfs_2.42.0.debian-trixie_amd64.deb
mergerfs -V                             # confirm >= 2.42.0
```
The upgrade does not touch data (files live on the ext4 branches `/mnt/data1-4`;
mergerfs is only a union view). It does require one remount of the pool — do it
in the maintenance window below.

### Layer 2 — Auto-restart mergerfs + auto-refresh exports
`config/systemd/mergerfs-media.service` replaces the fstab mergerfs mount with a
foreground service (`mergerfs -f`, `Restart=on-failure`). On a crash systemd
remounts the pool, re-points the `/exports/*` bind mounts at the fresh pool, and
runs `exportfs -ra` — turning a multi-hour outage into a ~5-second blip. Install
with `ansible-playbook -i inventory.yml playbooks/mergerfs-service.yml` (installs
the unit only; does not enable it). The playbook is intentionally excluded from
`site.yml` for the same reason.

> **Not yet adopted (as of 2026-08-21).** The unit is not installed on
> `cyl-homelab` and the pool is still mounted from `/etc/fstab`. This is the one
> outstanding layer.

> ⚠️ **Validate before enabling at boot.** The unit only touches mounts/exports,
> never data, but a bad unit can disrupt NFS *serving*. Adopting it requires
> commenting out the mergerfs line in `/etc/fstab` to avoid a double mount, then:
> ```bash
> sudo systemctl daemon-reload
> sudo systemctl enable --now mergerfs-media.service
> systemctl status mergerfs-media.service
> # Crash test: confirm auto-restart + clients still read afterwards
> sudo kill -SEGV "$(pgrep -x mergerfs)"
> sleep 8; systemctl status mergerfs-media.service   # should be active again
> ```

### Layer 3 — Make a remount transparent to NFS clients
The mergerfs options `noforget` (don't drop nodes NFS still references) and
`inodecalc=path-hash` (deterministic, path-derived inodes that stay stable
across branches and restarts) let NFS clients keep valid file handles across a
mergerfs remount — no more mass pod restarts. Added to both the fstab reference
(`config/system-configs/fstab`) and the service unit. Requires mergerfs >= 2.41.
Never *lazy*-umount the running pool: it leaves NFS exports hung until
`exportfs` runs (this is what broke exports during the incident).

### Layer 4 — Detect it: server-side NFS export health check
Layers 1–3 *prevent* and *auto-recover* from the crash; Layer 4 makes sure it's
*noticed* if it ever happens again. `scripts/monitor-storage.sh` (run every 5 min
by `disk-monitor.timer`, as root) now also validates the **server-side NFS
export layer** via `check_nfs_export_layer()`, which checks:

1. `nfs-server.service` is active (nfsd is serving).
2. Each `/exports/*` bind (`/exports/media`, `/exports/configs`,
   `/exports/games`) is mounted **and** readable within a timeout — a timed
   `stat` catches an ENOTCONN pool or a stale bind that would otherwise hang
   (the exact stale-handle source from the incident).
3. The kernel export table (`/proc/fs/nfs/exports`) lists the expected fsids
   (`fsid=1` media, `fsid=2` configs) — catches a dropped export where the bind
   looks fine locally but clients can't mount (the incident fix was
   `exportfs -ra`). `/exports/games` has no dedicated fsid (served via the
   pseudo-root) so it is checked as a bind but not as an fsid.

This is **advisory**: it logs and emits metrics but never triggers the array
lockdown, because a stale export is a *serving* problem, not a drive failure. It
complements the *remediation* in Layer 2 — detection here, auto-restart +
`exportfs -ra` there. Metrics are written to `nfs_export.prom` for the
node_exporter textfile collector (`nfs_export_status`, `nfs_server_active`,
`nfs_export_bind_accessible`, `nfs_export_fsid_present`,
`nfs_export_last_run_timestamp_seconds`) and alerted on by
`cluster/applications/monitoring/prometheus-rules-system-monitoring.yaml`
(`NFSServerDown`, `NFSExportBindStale`, `NFSExportMissing`, `NFSExportDegraded`,
`NFSExportCheckStale`). Quick manual read: `./scripts/monitor-storage.sh status`
(see the `=== NFS Export Layer ===` section).

> **History.** An earlier standalone `nfs-monitor.service` + `monitor-nfs-health.sh`
> existed but was removed in commit `f0d16c4` (2026-01-21, CSI→native-NFS
> migration) as "no longer needed" — it was a *client-side* CSI stale-mount
> watcher that couldn't remediate a server-side pool crash anyway. Its repo files
> were deleted cleanly, but the systemd units were left installed on the host and
> failed `203/EXEC` every minute for ~7 months until removed on 2026-08-21. The
> coverage that was actually missing (the server-side export layer) now lives in
> `monitor-storage.sh`, which is repo-tracked and deployed as the running unit.

### Nextcloud export — no dedicated export needed (verified)
The Nextcloud PV (`cluster/applications/cloud/nextcloud/storage-pvs.yaml`) uses
`path: /media/nextcloud`, which resolves via the persistent `/exports/media`
(`fsid=1`) export — Nextcloud's data is simply a subdirectory of the `/media`
export tree (same filesystem, no mount-crossing). Verified 2026-08-21 with a
read-only test pod mounting the plain `/media` export and reading
`nextcloud/`. A manually-added `fsid=3` export for `/media/nextcloud` is **not
required** and is not in `/etc/exports`; what un-sticks Nextcloud after a
remount is refreshing nfsd (`exportfs -ra`), now automated by Layer 2.

> **Cleanup note (resolved 2026-08-21).** Manual debugging during the incident
> left orphaned runtime bind mounts on the host that were **not** in `/etc/fstab`
> (`/media/nextcloud` — stacked twice, `/exports/media/nextcloud`,
> `/media/data/nextcloud`). The maintenance runbook below removed them; the only
> match left is the legitimate kubelet NFS mount for the Nextcloud PV. Re-check
> after any future incident:
> `grep -E '/media/nextcloud|/exports/media/nextcloud|/media/data/nextcloud' /proc/mounts`

### Maintenance-window runbook (host, requires sudo)

> **Status: completed 2026-08-21.** Layers 1 and 3 are live on `cyl-homelab`.
> Verified after the window:
> ```
> $ mergerfs -V
> mergerfs v2.42.0
> $ pgrep -a mergerfs
> 632 mergerfs /mnt/data1:/mnt/data2:/mnt/data3:/mnt/data4 /media/data \
>     -o rw,noatime,direct_io,minfreespace=51G,category.create=epmfs,\
>        moveonenospc=true,noforget,inodecalc=path-hash,dev,suid
> ```
> The orphaned incident-recovery binds are gone (`grep -E
> '/media/nextcloud|/exports/media/nextcloud|/media/data/nextcloud' /proc/mounts`
> returns only the legitimate kubelet NFS mount), `nfs-server` is active, and
> `/proc/fs/nfs/exports` lists `fsid=1` and `fsid=2`.
>
> **Layer 2 is still NOT adopted.** `mergerfs-media.service` is not installed on
> the host (`systemctl is-enabled mergerfs-media.service` → `not-found`) and the
> pool is still mounted from `/etc/fstab`. A mergerfs crash therefore still
> requires a manual remount — Layer 1's 2.42.0 ENOTCONN auto-unmount and Layer
> 3's stable handles reduce the blast radius, but nothing restarts the pool
> automatically yet. Adopt it via the Layer 2 steps above when you next have a
> window.
>
> Keep the runbook below for the next mergerfs upgrade or drive change.

Data is untouched by this runbook (options/exports/binaries only). One pool
remount briefly disrupts `/media`-backed pods; `/configs`-backed pods (separate
disk) are unaffected.
```bash
# 1. Layer 1 — upgrade mergerfs (see the Layer 1 commands above).
# 2. Layer 3 — add options to the /etc/fstab mergerfs line:
#      ...,moveonenospc=true,noforget,inodecalc=path-hash 0 0
#    (config/system-configs/fstab already reflects this.)
# 3. Remount the pool so the new binary + options take effect:
sudo systemctl stop nfs-server            # quiesce clients
# clear the orphaned incident-recovery binds (ignore "not mounted" errors):
sudo umount -l /media/nextcloud /media/nextcloud /exports/media/nextcloud /media/data/nextcloud 2>/dev/null
sudo umount -l /exports/media /exports/games
sudo umount /media/data || sudo fusermount -uz /media/data
sudo mount /media/data                     # picks up new options (or start the service, Layer 2)
sudo mount --bind /media/data /exports/media
sudo mount --bind /media/data/games /exports/games
sudo exportfs -ra
sudo systemctl start nfs-server
# 3b. Verify the new binary + options are actually live. NOTE: mergerfs-internal
#     options (noforget/inodecalc/moveonenospc) do NOT appear in /proc/mounts —
#     FUSE only exposes kernel flags there. Check the running process instead:
mergerfs --version                         # expect >= 2.42.0
pgrep -a mergerfs                          # options must include noforget,inodecalc=path-hash
# 4. Restart the /media-backed pods once to clear any old handles. Exact set
#    (deployments mounting a /media PV on 192.168.1.94):
#      kubectl -n automation rollout restart deploy/home-assistant
#      kubectl -n cloud      rollout restart deploy/immich-server deploy/nextcloud
#      kubectl -n media      rollout restart deploy/jellyfin deploy/qbittorrent deploy/radarr deploy/sonarr
```