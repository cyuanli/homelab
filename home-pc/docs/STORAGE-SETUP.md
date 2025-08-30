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

**🎯 Result**: You now have a unified `/media/data` directory with all your drives pooled together and protected by SnapRAID parity!

Your Nextcloud (and other services) can use `/media/data/nextcloud` for multi-terabyte storage with redundancy protection.