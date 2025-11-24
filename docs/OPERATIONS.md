# Operations Guide

This guide covers day-to-day operations, maintenance tasks, and management procedures for the homelab infrastructure.

## Daily Operations

### Health Monitoring

**Quick Health Check**
```bash
# Check overall system status
./scripts/homelab.sh status

# Check individual components
kubectl get nodes                    # Cluster nodes
kubectl get pods -A                  # All pods
sudo tailscale status               # VPN connectivity
df -h                               # Disk usage
```

**Service-Specific Checks**
```bash
# Media stack
kubectl get pods -n media
kubectl logs -n media deployment/jellyfin --tail=50

# Cloud services
kubectl get pods -n cloud
kubectl logs -n cloud deployment/nextcloud --tail=50

# Infrastructure
kubectl get pods -n kube-system
kubectl logs -n kube-system deployment/traefik --tail=50
```

### Log Monitoring

**View Service Logs**
```bash
# Using homelab script
./scripts/homelab.sh logs jellyfin
./scripts/homelab.sh logs nextcloud
./scripts/homelab.sh logs traefik

# Direct kubectl
kubectl logs -n media deployment/jellyfin -f
kubectl logs -n cloud deployment/nextcloud -f
```

**System Logs**
```bash
# K3s service logs
journalctl -u k3s -f

# Storage monitoring logs
journalctl -u storage-monitor -f

# System logs
journalctl -f
```

### Storage Monitoring

**Check Storage Status**
```bash
# Check monitoring status
./scripts/homelab.sh monitor status

# Check disk usage
df -h /media/data
df -h /opt/k3s-storage

# Check drive health (if using SMART)
sudo smartctl -H /dev/sda
```

**Test Monitoring System**
```bash
# Check monitoring status
./scripts/homelab.sh monitor status

# View disk metrics
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom

# Manual monitoring check
./scripts/monitor-storage.sh check
```

## Service Management

### Starting and Stopping Services

**Individual Services**
```bash
# Restart a service
./scripts/homelab.sh restart jellyfin

# Scale service to zero (stop)
kubectl scale deployment/jellyfin -n media --replicas=0

# Scale service back up
kubectl scale deployment/jellyfin -n media --replicas=1
```

**Service Groups**
```bash
# Restart all media services
./scripts/homelab.sh deploy media

# Stop all services in a namespace
kubectl scale deployment --all -n media --replicas=0

# Start all services in a namespace
kubectl scale deployment --all -n media --replicas=1
```

### Service Configuration Updates

**Update Environment Variables**
```bash
# Edit main configuration
nano config/homelab.env

# Redeploy affected services
./scripts/homelab.sh deploy media
```

**Update Application Images**
```bash
# Edit version in config
nano config/homelab.env
# Change: JELLYFIN_VERSION="10.8.13"

# Or edit kustomization directly
nano cluster/applications/media-stack/jellyfin/kustomization.yaml

# Deploy update
kubectl apply -k cluster/applications/media-stack/jellyfin/
```

**Rolling Updates**
```bash
# Force rolling update (restart all pods)
kubectl rollout restart deployment/jellyfin -n media

# Check rollout status
kubectl rollout status deployment/jellyfin -n media

# View rollout history
kubectl rollout history deployment/jellyfin -n media
```

## Cluster Management

### Node Operations

**Add New Node**
```bash
# Generate configuration for agent node (worker)
./scripts/manage-nodes.sh add worker2

# Or generate configuration for control plane node
./scripts/manage-nodes.sh add control2 --role server

# Copy homelab to new node
scp -r ~/homelab user@worker2:~/

# On new node, run setup
ssh user@worker2
cd ~/homelab
./scripts/homelab.sh setup-system
./scripts/homelab.sh setup-cluster
```

**Note**: For HA control plane, use 3 or 5 server nodes (odd number for etcd quorum).

**Remove Node**
```bash
# Drain node gracefully
./scripts/manage-nodes.sh drain worker2

# Remove from cluster
./scripts/manage-nodes.sh remove worker2
```

**Node Maintenance**
```bash
# Check node status
kubectl get nodes -o wide

# Describe node for details
kubectl describe node worker2

# Cordon node (prevent new pods)
kubectl cordon worker2

# Uncordon node
kubectl uncordon worker2
```

**Convert Agent to Control Plane**
```bash
# 1. Update node configuration
nano ~/homelab/nodes/worker2/config.env.local
# Change: NODE_ROLE=agent → NODE_ROLE=server

# 2. On the agent node, uninstall K3s
ssh user@worker2
sudo /usr/local/bin/k3s-agent-uninstall.sh
sudo rm -rf /var/lib/rancher /etc/rancher /var/lib/kubelet
sudo rm -rf ~/.kube

# 3. Re-run cluster setup (will install as server)
cd ~/homelab
./scripts/setup-cluster.sh

# 4. Verify node joined as control plane
kubectl get nodes -l node-role.kubernetes.io/control-plane
```

### Cluster Updates

**Update K3s**
```bash
# Check current version
kubectl version

# Update K3s binary (manual process)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.9+k3s1 sh -

# Restart K3s
sudo systemctl restart k3s

# Verify update
kubectl version
```

**Update System Packages**
```bash
# Update base system
sudo apt update && sudo apt upgrade -y

# Update Docker (if needed)
sudo apt update docker-ce docker-ce-cli containerd.io

# Reboot if kernel updated
sudo reboot
```

## Application Management

### Media Stack Operations

**Prowlarr Management**
```bash
# Access: https://prowlarr.your-domain.com
# Default credentials: none (setup required)

# Common tasks:
# - Add indexers for content discovery
# - Configure API keys for Sonarr/Radarr
# - Test indexer connections
```

**Sonarr/Radarr Management**
```bash
# Access: https://sonarr.your-domain.com
#         https://radarr.your-domain.com

# Common tasks:
# - Add TV shows/movies
# - Configure download clients
# - Monitor download progress
# - Manage quality profiles
```

**qBittorrent Management**
```bash
# Access: https://qbittorrent.your-domain.com
# Default credentials: admin/adminadmin (change immediately)

# Common tasks:
# - Monitor active downloads
# - Configure download categories
# - Set speed limits
# - Manage completed downloads
```

**Jellyfin Management**
```bash
# Access: https://jellyfin.your-domain.com

# Common tasks:
# - Add media libraries
# - Manage users and permissions
# - Configure transcoding settings
# - Monitor server performance
```

### Nextcloud Operations

**Basic Management**
```bash
# Access: https://drive.your-domain.com

# Common tasks:
# - User management
# - App installation/updates
# - Storage configuration
# - Security settings
```

**Maintenance Mode**
```bash
# Enable maintenance mode
kubectl exec -it -n cloud deployment/nextcloud -- \
  sudo -u www-data php occ maintenance:mode --on

# Disable maintenance mode
kubectl exec -it -n cloud deployment/nextcloud -- \
  sudo -u www-data php occ maintenance:mode --off
```

**Database Operations**
```bash
# Connect to PostgreSQL
kubectl exec -it -n cloud deployment/postgres -- \
  psql -U nextcloud -d nextcloud

# Backup database
kubectl exec -it -n cloud deployment/postgres -- \
  pg_dump -U nextcloud nextcloud > nextcloud-backup.sql
```

## Backup and Recovery

### Backup Operations

**Manual Backup**
```bash
# Backup application data
tar -czf homelab-backup-$(date +%Y%m%d).tar.gz \
  /opt/k3s-storage/ \
  /media/data/ \
  config/

# Backup Kubernetes configs
kubectl get all -A -o yaml > k8s-backup-$(date +%Y%m%d).yaml
```

**Automated Backup (Borgmatic)**
```bash
# Check backup status
./scripts/backup-notify.sh status

# Run manual backup
./scripts/backup-notify.sh run

# List backup archives
./scripts/backup-notify.sh list
```

### Recovery Procedures

**Application Recovery**
```bash
# Recreate application from manifests
kubectl delete -k cluster/applications/media-stack/jellyfin/
kubectl apply -k cluster/applications/media-stack/jellyfin/

# Wait for recovery
kubectl wait --for=condition=ready pod -l app=jellyfin -n media
```

**Data Recovery**
```bash
# Stop applications
kubectl scale deployment --all -n media --replicas=0

# Restore data from backup
tar -xzf homelab-backup-20231201.tar.gz -C /

# Restart applications
kubectl scale deployment --all -n media --replicas=1
```

**Complete Cluster Recovery**
```bash
# Reinstall K3s
sudo /usr/local/bin/k3s-uninstall.sh
./scripts/homelab.sh setup-cluster

# Restore applications
./scripts/homelab.sh deploy

# Restore data
# (restore from backup as above)
```

## Network Operations

### Tailscale Management

**Check Tailscale Status**
```bash
# View connection status
sudo tailscale status

# Check network connectivity
sudo tailscale ping vps-hostname
sudo tailscale ping 100.x.x.x
```

**Tailscale Updates**
```bash
# Update Tailscale
sudo tailscale update

# Restart Tailscale if needed
sudo systemctl restart tailscaled
```

### VPS Proxy Operations

**VPS Health Check**
```bash
# On VPS, check services
sudo systemctl status nginx tailscaled

# Check proxy logs
sudo tail -f /var/log/nginx/stream_access.log
sudo tail -f /var/log/nginx/stream_error.log

# Test connectivity from VPS to homelab
curl -I http://100.x.x.x  # homelab Tailscale IP
```

**Update VPS Configuration**
```bash
# Update VPS configs
cd vps/
git pull
sudo systemctl restart nginx
```

### SSL Certificate Management

**Check Certificate Status**
```bash
# View all certificates
kubectl get certificates -A

# Check specific certificate
kubectl describe certificate nextcloud-tls -n cloud

# Check Traefik ACME storage
kubectl exec -n kube-system deployment/traefik -- \
  cat /acme/acme.json | jq '.le.Certificates[] | .domain'
```

**Force Certificate Renewal**
```bash
# Delete certificate to force renewal
kubectl delete certificate nextcloud-tls -n cloud

# Check Traefik logs for renewal
kubectl logs -n kube-system deployment/traefik -f
```

## Monitoring and Alerting

### Prometheus Metrics

All monitoring is centralized through Prometheus/Alertmanager.

**View Metrics**
```bash
# Disk monitoring metrics
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom

# Backup metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom

# SnapRAID metrics
cat /var/lib/node_exporter/textfile_collector/snapraid.prom
```

**Check Alerts**
```bash
# View alert rules
kubectl get configmap -n monitoring prometheus-alerts -o yaml | grep "alert:"

# Check active alerts in Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Then visit: http://localhost:9090/alerts
```

**Configure Notifications**
```bash
# Edit monitoring configuration
nano config/service-configs/monitoring.conf

# Restart monitoring
./scripts/homelab.sh monitor restart
```

### Performance Monitoring

**Resource Usage**
```bash
# Check node resource usage
kubectl top nodes

# Check pod resource usage
kubectl top pods -A

# System resource usage
htop
iotop
```

**Storage Performance**
```bash
# Test disk performance
sudo hdparm -Tt /dev/sda

# Check I/O statistics
iostat -x 1

# Monitor disk usage growth
du -sh /media/data/* | sort -h
```

## Security Operations

### Access Management

**Update Authentication**
```bash
# Regenerate admin credentials
./scripts/homelab.sh setup-auth

# Update service credentials manually
nano config/service-configs/auth.conf
kubectl apply -k cluster/applications/
```

**SSH Key Management**
```bash
# Add new SSH key
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Remove old SSH key
nano ~/.ssh/authorized_keys
```

### Security Updates

**System Security Updates**
```bash
# Install security updates
sudo apt update
sudo apt upgrade -y

# Check for pending updates
apt list --upgradable
```

**Container Image Updates**
```bash
# Update all container images
./scripts/homelab.sh deploy

# Update specific service
kubectl set image deployment/jellyfin \
  jellyfin=jellyfin/jellyfin:latest -n media
```

## Maintenance Schedules

### Daily Tasks
- [ ] Check service status
- [ ] Review logs for errors
- [ ] Monitor disk usage
- [ ] Verify backup completion

### Weekly Tasks
- [ ] Review security logs
- [ ] Check for application updates
- [ ] Test monitoring alerts
- [ ] Verify SSL certificate status

### Monthly Tasks
- [ ] Update system packages
- [ ] Review and rotate logs
- [ ] Performance monitoring review
- [ ] Backup verification test

### Quarterly Tasks
- [ ] K3s version update
- [ ] Security audit
- [ ] Disaster recovery test
- [ ] Documentation updates

## Automation

### Scheduled Tasks

**Crontab Examples**
```bash
# Edit crontab
crontab -e

# Daily health check at 6 AM
0 6 * * * /home/user/homelab/scripts/homelab.sh status > /var/log/homelab-status.log

# Weekly cleanup at 2 AM Sunday
0 2 * * 0 docker system prune -f

# Monthly backup verification
0 3 1 * * /home/user/homelab/scripts/backup-notify.sh verify
```

### Monitoring Scripts

**Custom Health Checks**
```bash
#!/bin/bash
# ~/bin/homelab-health.sh

# Check all services are running
if ! ./scripts/homelab.sh status | grep -q "All systems operational"; then
    echo "Homelab health check failed" | \
        curl -X POST $DISCORD_WEBHOOK_URL \
        -H "Content-Type: application/json" \
        -d @- <<< '{"content": "'$(cat)'"}'
fi
```

## Troubleshooting Quick Reference

**Common Commands**
```bash
# Service not responding
kubectl get pods -A | grep -v Running
kubectl describe pod <pod-name> -n <namespace>

# Storage issues
df -h
./scripts/homelab.sh monitor status

# Network issues
sudo tailscale status
kubectl get svc -A

# Certificate issues
kubectl get certificates -A
kubectl logs -n kube-system deployment/traefik
```

**Emergency Procedures**
```bash
# Stop all workloads (storage failure)
./scripts/monitor-storage.sh stop-workloads

# Emergency cluster restart
sudo systemctl restart k3s
kubectl get nodes

# Emergency service restart
./scripts/homelab.sh deploy <service>
```

This operations guide provides the foundation for managing your homelab infrastructure effectively. Regular adherence to these procedures ensures optimal performance and reliability.