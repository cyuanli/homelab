# Operations Guide

## Daily Commands

```bash
./scripts/homelab.sh status      # Cluster health
kubectl get pods -A              # All pods
kubectl logs -n <ns> deployment/<svc> --tail=50  # Service logs
```

## Service Management

```bash
# Restart a service
kubectl rollout restart deployment/<service> -n <namespace>

# Scale down (stop)
kubectl scale deployment/<service> -n <namespace> --replicas=0

# Scale up
kubectl scale deployment/<service> -n <namespace> --replicas=1

# Redeploy
kubectl apply -k cluster/applications/<category>/<service>/
```

## Node Management

```bash
# Add new node
./scripts/manage-nodes.sh add <hostname> --role server  # or agent

# On new node
./scripts/homelab.sh setup-system
./scripts/homelab.sh setup-cluster

# Drain node for maintenance
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Return to service
kubectl uncordon <node>
```

## Backups (Borgmatic)

Automated backups using borgmatic with systemd timer (daily at 3:00 AM).

### Installation

```bash
sudo apt install borgmatic
sudo mkdir -p /etc/borgmatic
sudo cp config/templates/borgmatic.yaml.template /etc/borgmatic/config.yaml
# Edit with your backup repositories and passphrase

# Copy notification script for hooks
sudo cp scripts/backup-notify.sh /etc/borgmatic/hooks/
sudo chmod +x /etc/borgmatic/hooks/backup-notify.sh

# Enable timer
sudo cp config/borgmatic/systemd/*.service /etc/systemd/system/
sudo cp config/borgmatic/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now borgmatic.timer
```

### Commands

```bash
# Check borgmatic status
sudo systemctl status borgmatic.timer
journalctl -u borgmatic.service -n 50

# Manual backup
sudo systemctl start borgmatic.service

# View backup metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom
```

Alerts via Prometheus/Alertmanager. See `cluster/applications/monitoring/`.

## Scheduled Tasks (Systemd Timers)

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `snapraid-runner` | Daily 2 AM | SnapRAID sync/scrub |
| `disk-monitor` | Every 5 min | Disk health checks |
| `borgmatic` | Daily 3 AM | Backups |

```bash
systemctl list-timers                    # All timers
journalctl -u <service>.service -n 50   # Timer logs
sudo systemctl start <service>.service  # Manual trigger
```

### Installing Timers

```bash
# Copy timer and service files
sudo cp /home/cyl/homelab/config/systemd/*.timer /etc/systemd/system/
sudo cp /home/cyl/homelab/config/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload

# Enable timers
sudo systemctl enable --now snapraid-runner.timer
sudo systemctl enable --now disk-monitor.timer
```

## Monitoring

```bash
# Prometheus metrics
cat /var/lib/node_exporter/textfile_collector/*.prom

# Grafana: https://grafana.cliff.li
# Prometheus: https://prometheus.cliff.li
# Alertmanager: https://alertmanager.cliff.li
```

### Monitoring Setup (One-time)

**Disk health monitoring** (for SnapRAID storage nodes):

```bash
# Create monitoring config from template
cp config/service-configs/monitoring.conf.template config/service-configs/monitoring.conf
# Edit with your drive configuration

# Add cron job for disk monitoring (runs every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/homelab/scripts/monitor-storage.sh check >/dev/null 2>&1") | crontab -

# Test it works
./scripts/monitor-storage.sh status
```

**Backup monitoring** (if using borgmatic):

```bash
# Install borgmatic
sudo apt install borgmatic

# Create borgmatic config
sudo mkdir -p /etc/borgmatic
sudo cp config/templates/borgmatic.yaml.template /etc/borgmatic/config.yaml
# Edit with your backup repositories and passphrase

# Copy notification script for hooks
sudo cp scripts/backup-notify.sh /etc/borgmatic/hooks/
sudo chmod +x /etc/borgmatic/hooks/backup-notify.sh

# Enable systemd timer for daily backups
sudo systemctl enable borgmatic.timer
sudo systemctl start borgmatic.timer
```

## Certificate Management

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>

# Force renewal
kubectl delete certificaterequest -n <namespace> <request-name>
```

## VPS Proxy

```bash
# On VPS
sudo systemctl status nginx tailscaled
sudo tail -f /var/log/nginx/stream_error.log

# Test connectivity
curl -I http://100.x.x.x  # Homelab Tailscale IP
```
