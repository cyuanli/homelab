# Storage: SnapRAID + MergerFS

## Overview

```
Data Drives (/mnt/data1..4)  →  MergerFS  →  /media/data (unified pool)
Parity Drive (/mnt/parity1)  →  SnapRAID  →  Data protection
                                    ↓
                              NFS Export  →  K8s PVs
```

- **MergerFS**: Combines multiple drives into single `/media/data` directory
- **SnapRAID**: Parity-based protection (can recover from 1 drive failure)
- **NFS**: Exports storage to all cluster nodes

## Setup

**For detailed step-by-step setup, see: [STORAGE-SETUP.md](./STORAGE-SETUP.md)**

## Daily Operations

```bash
# Check status
sudo snapraid status
df -h /media/data

# Manual sync
sudo snapraid sync

# Check integrity
sudo snapraid scrub
```

## Drive Failure Recovery

1. Replace failed drive
2. Format and mount to same location
3. Restore: `sudo snapraid fix -d <drive_name>`

## Monitoring

Disk health monitored via systemd timer (every 5 min). Alerts via Prometheus/Alertmanager.

```bash
# Check monitoring
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom
journalctl -u disk-monitor.service -n 20
```

## Key Files

- `/etc/fstab` - Mount configuration
- `/etc/snapraid.conf` - SnapRAID config
- `/etc/exports` - NFS exports
