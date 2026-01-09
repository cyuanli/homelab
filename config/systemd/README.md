# systemd Timer Configuration

This directory contains systemd timer and service unit files for scheduled tasks in the homelab.

## Overview

All scheduled tasks use systemd timers for consistency, maintainability, and better logging/monitoring.

### Timers

1. **snapraid-runner** - Daily SnapRAID sync/scrub at 2:00 AM
2. **disk-monitor** - Disk health monitoring every 5 minutes
3. **nfs-monitor** - NFS mount health monitoring every 5 minutes

## Installation

To install these systemd timers:

```bash
# Copy timer and service files to systemd directory
sudo cp /home/cyl/homelab/config/systemd/*.timer /etc/systemd/system/
sudo cp /home/cyl/homelab/config/systemd/*.service /etc/systemd/system/

# Reload systemd to recognize new units
sudo systemctl daemon-reload

# Enable and start the timers
sudo systemctl enable --now snapraid-runner.timer
sudo systemctl enable --now disk-monitor.timer
sudo systemctl enable --now nfs-monitor.timer
```

## Monitoring

### Check all timer status
```bash
systemctl list-timers
```

### Check specific timer
```bash
systemctl status snapraid-runner.timer
systemctl status disk-monitor.timer
systemctl status nfs-monitor.timer
```

### View service logs
```bash
# View recent logs
journalctl -u snapraid-runner.service -n 50
journalctl -u disk-monitor.service -n 50
journalctl -u nfs-monitor.service -n 50

# Follow logs in real-time
journalctl -u disk-monitor.service -f
```

### Manual execution
```bash
# Trigger a service manually (doesn't wait for timer)
sudo systemctl start snapraid-runner.service
sudo systemctl start disk-monitor.service
sudo systemctl start nfs-monitor.service
```

## Schedule Details

- **snapraid-runner**: `OnCalendar=02:00` - Runs daily at 2:00 AM local time
- **disk-monitor**: `OnUnitActiveSec=5min` - Runs every 5 minutes, starts 2 minutes after boot
- **nfs-monitor**: `OnUnitActiveSec=5min` - Runs every 5 minutes, starts 2 minutes after boot

All timers use `Persistent=true` to run missed executions after system boot.
