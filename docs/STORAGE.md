# Storage Setup: SnapRAID + MergerFS

This homelab uses **SnapRAID + MergerFS** to create a unified storage pool (`/media/data`) with redundancy protection.

## Setup Guide

**⚠️ For detailed step-by-step setup instructions, see: [STORAGE-SETUP.md](./STORAGE-SETUP.md)**

The manual setup process covers:
1. **Drive identification and planning** 
2. **Safe drive preparation** (with data preservation options)
3. **System configuration** (fstab, SnapRAID config)
4. **Verification and testing**
5. **Automated maintenance setup**

### 💡 Why Manual Setup?
- **Storage is critical** - mistakes can cause data loss
- **Every setup is different** - drive sizes, existing data, preferences
- **Educational** - understand what each step does
- **Safer** - you control every operation

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Data Drive 1  │    │   Data Drive 2  │    │   Parity Drive  │
│   /mnt/data1    │    │   /mnt/data2    │    │   /mnt/parity1  │
│      ext4       │    │      ext4       │    │       XFS       │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────────────┐
                    │      MergerFS Pool      │
                    │      /media/data        │
                    │   (Unified Access)      │
                    └─────────────────────────┘
                                 │
                    ┌─────────────────────────┐
                    │     SnapRAID Parity     │
                    │   (Data Protection)     │
                    └─────────────────────────┘
```

## How It Works

**MergerFS**: Creates a single `/media/data` directory that combines multiple drives
- Files automatically distributed across drives
- Mixed drive sizes supported
- New drives easily added

**SnapRAID**: Provides data protection through parity
- Dedicated parity drive stores recovery information
- Can recover data if **one** drive fails
- Parity calculated on schedule (not real-time)

## Key Features

### ✅ Advantages
- **Mixed drive sizes**: Use whatever drives you have
- **High performance**: No real-time parity overhead
- **Cost effective**: No need to buy drives in pairs
- **Flexible**: Add drives anytime
- **Linux native**: Works on any Linux system

### ⚠️ Limitations  
- **Single drive protection**: Can only recover from 1 drive failure
- **Not real-time**: New files unprotected until next sync
- **Manual recovery**: Requires commands to restore failed drives

## Daily Operations

### Check Status
```bash
# Overall array status
sudo snapraid status

# Storage space
df -h /media/data

# Recent sync logs
tail -f /var/log/snapraid.log
```

### Manual Operations
```bash
# Force sync (if needed)
sudo snapraid sync

# Check data integrity  
sudo snapraid scrub

# Fix corrupted files
sudo snapraid fix
```

## Drive Failure Recovery

If a data drive fails:

1. **Replace the failed drive**
2. **Format and mount** the new drive in same location
3. **Restore data** from parity:
   ```bash
   sudo snapraid fix -d <drive_name>
   ```

## Configuration Files

- **MergerFS**: `/etc/fstab` (mount configuration)
- **SnapRAID**: `/etc/snapraid.conf` (drives and exclusions)
- **Automation**: `/etc/snapraid-runner.conf` (scheduled maintenance)

## Automation

**Daily Sync**: Runs at 2 AM via cron
```bash
# View/edit cron jobs
sudo crontab -e

# Manual run of automated sync
sudo /usr/local/bin/snapraid-runner
```

## Integration with Services

### Nextcloud
- Data stored in `/media/data/nextcloud`
- Permissions set for www-data (UID 33)
- Multi-TB capacity ready

### Adding New Services
Simply point services to subdirectories under `/media/data/`:
- `/media/data/media` for media files (movies, TV, music)
- `/media/data/downloads` for download clients
- `/media/data/backups` for backup storage

## Monitoring

### Log Files
```bash
# SnapRAID operations
tail -f /var/log/snapraid.log

# System disk usage
watch df -h
```

### Health Checks
```bash
# Drive health
sudo smartctl -a /dev/sd<X>

# Array consistency  
sudo snapraid status
```

## Troubleshooting

### Common Issues

**"Too many deleted files"**: 
```bash
# Check what changed
sudo snapraid diff

# Force sync if safe
sudo snapraid sync -h
```

**Drive not mounting**:
```bash
# Check fstab syntax
sudo mount -a

# Manual mount test
sudo mount UUID=<uuid> /mnt/data1
```

**Parity errors**:
```bash
# Scrub to find issues
sudo snapraid scrub

# Fix specific files
sudo snapraid fix
```

## Adding Drives Later

### 📁 Adding Data Drives (With Existing Data)
If your new drive already has data you want to keep:

1. **Check filesystem**: `lsblk -f /dev/sdX1`
2. **If ext4**: Can preserve data ✅
   ```bash
   # Mount the drive temporarily 
   sudo mkdir /mnt/temp
   sudo mount /dev/sdX1 /mnt/temp
   
   # Check what's on it
   ls -la /mnt/temp
   sudo umount /mnt/temp
   ```
3. **Add to configuration**:
   ```bash
   # Get UUID
   sudo blkid /dev/sdX1
   
   # Add to /etc/fstab
   UUID=your-uuid /mnt/data3 ext4 defaults,noatime 0 2
   
   # Update MergerFS line to include :/mnt/data3
   
   # Add to /etc/snapraid.conf
   data d3 /mnt/data3
   content /mnt/data3/snapraid.content
   ```
4. **Activate**:
   ```bash
   sudo mount -a
   sudo snapraid sync  # Protect existing data
   ```

### 💾 Adding Empty Data Drives  
1. Format new drive with ext4
2. Add to `/etc/fstab` 
3. Add to `/etc/snapraid.conf`
4. Update MergerFS mount in fstab
5. Run `sudo snapraid sync`

### Adding Parity Drives
1. Format new drive with XFS
2. Add to `/etc/snapraid.conf` as `parity2`
3. Run `sudo snapraid sync`

## Performance Tips

- **XFS for parity drives**: Better large file performance
- **noatime**: Reduces write overhead  
- **Separate parity controller**: Put parity drive on different SATA controller
- **SSD cache**: Consider SSD for frequently accessed files

---

**Created**: $(date)
**Script**: `./scripts/setup-storage.sh`
**Support**: SnapRAID documentation at snapraid.it