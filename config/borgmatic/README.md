# Borgmatic Backup Setup

## Overview
This directory contains the configuration for automated backups using borgmatic with systemd timer scheduling and Prometheus metrics export.

## Files
- `systemd/borgmatic.service` - Systemd service unit for running borgmatic
- `systemd/borgmatic.timer` - Systemd timer for daily backup scheduling (3:00 AM)
- `config.yaml` - Borgmatic backup configuration with hooks for metrics export
- `../../scripts/backup-notify.sh` - Exports backup success/failure metrics to Prometheus

## Installation

### 1. Install Borgmatic
```bash
sudo apt install borgmatic
```

### 2. Copy Configuration
```bash
sudo cp config.yaml /etc/borgmatic/config.yaml
```

### 3. Install Systemd Units
```bash
sudo cp systemd/borgmatic.service /etc/systemd/system/
sudo cp systemd/borgmatic.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

### 4. Enable and Start
```bash
sudo systemctl enable borgmatic.timer
sudo systemctl start borgmatic.timer
```

## Monitoring

### Check Timer Status
```bash
sudo systemctl status borgmatic.timer
```

### Check Last Backup Run
```bash
sudo systemctl status borgmatic.service
journalctl -u borgmatic.service
```

### Manual Backup
```bash
sudo systemctl start borgmatic.service
```

### Test Metrics Export
```bash
# Test success metrics export
/home/cyl/homelab/scripts/backup-notify.sh success

# Test failure metrics export
/home/cyl/homelab/scripts/backup-notify.sh error

# View exported metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom
```

### Alerting
Backup alerts are handled by Prometheus/Alertmanager. See:
- Alert rules: `cluster/applications/monitoring/prometheus/alerts.yaml`
- Alertmanager config: `cluster/applications/monitoring/alertmanager/alertmanager.yaml`

## Configuration Details

### Service Configuration
- **Nice level**: 10 (lower priority)
- **IO Scheduling**: Best effort, priority 7
- **Notifications**:
  - Success: Sent via `ExecStartPost`
  - Failure: Sent via `ExecStopPost`

### Timer Schedule
- Runs daily at 3:00 AM
- Persistent across reboots
- Part of `timers.target`

### Notification Script
The notification script sends Discord notifications for both successful and failed backups, including recent log entries for failures.

### K3s Integration
The backup hooks use kubectl to enable/disable Nextcloud maintenance mode before and after backups:
- Before backup: `kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ maintenance:mode --on"`
- After backup: `kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ maintenance:mode --off"`
