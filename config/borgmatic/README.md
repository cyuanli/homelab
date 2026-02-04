# Borgmatic Backup

Automated backups using borgmatic with systemd timer (daily at 3:00 AM).

## Installation

```bash
sudo apt install borgmatic
sudo cp config.yaml /etc/borgmatic/config.yaml
sudo cp systemd/borgmatic.service /etc/systemd/system/
sudo cp systemd/borgmatic.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now borgmatic.timer
```

## Commands

```bash
# Check status
sudo systemctl status borgmatic.timer
journalctl -u borgmatic.service -n 50

# Manual backup
sudo systemctl start borgmatic.service

# View metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom
```

## Monitoring

Alerts via Prometheus/Alertmanager. See `cluster/applications/monitoring/`.
