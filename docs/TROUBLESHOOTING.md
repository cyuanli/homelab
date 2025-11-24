# Troubleshooting Guide

This guide provides systematic approaches to diagnosing and resolving common issues in the homelab infrastructure.

## General Troubleshooting Approach

### Step-by-Step Methodology

1. **Identify the Problem**
   - What service/component is affected?
   - When did the issue start?
   - What changed recently?

2. **Gather Information**
   - Check service status
   - Review logs
   - Verify configuration
   - Test connectivity

3. **Isolate the Issue**
   - Test individual components
   - Check dependencies
   - Verify external services

4. **Implement Solution**
   - Apply fix incrementally
   - Test after each change
   - Document the resolution

### Essential Diagnostic Commands

```bash
# Overall system status
./scripts/homelab.sh status

# Cluster health
kubectl get nodes
kubectl get pods -A
kubectl get events --sort-by='.lastTimestamp' -A

# Network connectivity
sudo tailscale status
ping google.com
curl -I https://your-domain.com

# Storage health
df -h
./scripts/homelab.sh monitor status

# Service logs
kubectl logs -n <namespace> deployment/<service> --tail=50
journalctl -u k3s --tail=50
```

## Service-Specific Issues

### Pods Not Starting

**Symptoms**
- Pods stuck in Pending, CrashLoopBackOff, or ImagePullBackOff states
- Services not accessible
- `kubectl get pods` shows non-Running status

**Diagnosis**
```bash
# Check pod status and events
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>

# Check node resources
kubectl top nodes
kubectl describe node <node-name>

# Check events
kubectl get events --sort-by='.lastTimestamp' -A
```

**Common Causes & Solutions**

**Resource Constraints**
```bash
# Check resource usage
kubectl top nodes
kubectl top pods -A

# Solution: Add resource limits or scale down services
kubectl edit deployment <deployment-name> -n <namespace>
# Add or modify resources section:
# resources:
#   requests:
#     memory: "256Mi"
#     cpu: "250m"
#   limits:
#     memory: "512Mi"
#     cpu: "500m"
```

**Storage Issues**
```bash
# Check persistent volume claims
kubectl get pv
kubectl get pvc -A

# Check storage permissions
ls -la /opt/k3s-storage/
sudo chown -R $USER:$USER /opt/k3s-storage/

# Solution: Fix permissions or recreate PVs
kubectl delete pvc <pvc-name> -n <namespace>
kubectl apply -k cluster/applications/<service>/
```

**Image Pull Failures**
```bash
# Check image names and tags
kubectl describe pod <pod-name> -n <namespace>

# Solution: Verify image exists and fix tag
kubectl edit deployment <deployment-name> -n <namespace>
# Update image tag to known working version
```

**Configuration Errors**
```bash
# Check ConfigMaps and Secrets
kubectl get configmap -n <namespace>
kubectl get secrets -n <namespace>

# Validate YAML syntax
kubectl apply --dry-run=client -k cluster/applications/<service>/

# Solution: Fix configuration and redeploy
nano cluster/applications/<service>/<file>.yaml
kubectl apply -k cluster/applications/<service>/
```

### Network Connectivity Issues

**Symptoms**
- Services not accessible via ingress
- Internal service communication failures
- SSL certificate issues

**Diagnosis**
```bash
# Check Traefik status
kubectl get pods -n kube-system | grep traefik
kubectl logs -n kube-system deployment/traefik --tail=50

# Check ingress resources
kubectl get ingress -A
kubectl describe ingress <ingress-name> -n <namespace>

# Check services
kubectl get services -A
kubectl describe service <service-name> -n <namespace>

# Test internal connectivity
kubectl exec -it -n utilities deployment/whoami -- wget -qO- http://jellyfin.media:8096
```

**Common Causes & Solutions**

**Traefik Configuration Issues**
```bash
# Check Traefik configuration
kubectl logs -n kube-system deployment/traefik | grep -i error

# Check ingress annotations
kubectl describe ingress <ingress-name> -n <namespace>

# Solution: Fix ingress configuration
nano cluster/applications/<service>/ingress.yaml
kubectl apply -k cluster/applications/<service>/
```

**SSL Certificate Problems**
```bash
# Check certificate status
kubectl get certificates -A
kubectl describe certificate <cert-name> -n <namespace>

# Check ACME challenges
kubectl logs -n kube-system deployment/traefik | grep -i acme

# Solution: Delete certificate to force renewal
kubectl delete certificate <cert-name> -n <namespace>
# Certificate will be automatically recreated
```

**DNS Resolution Issues**
```bash
# Check DNS from within cluster
kubectl exec -it -n utilities deployment/whoami -- nslookup google.com

# Check external DNS
nslookup your-domain.com

# Solution: Verify DNS configuration
# Check domain A records point to VPS IP
# Verify internal Kubernetes DNS is working
```

**Cross-Node Pod Communication Failure (VXLAN)**

If pods on worker nodes cannot reach pods on other nodes (including CoreDNS), check if Flannel VXLAN traffic is blocked:

```bash
# Symptom: DNS resolution fails on worker nodes but works on control plane
# Symptom: Cannot ping pods on other nodes (e.g., ping 10.42.0.4 times out)

# Test cross-node connectivity
kubectl run test-pod --image=busybox --rm -it -- ping <pod-ip-on-other-node>

# Check if vxlan interface exists
ip addr show flannel.1

# Check if vxlan port is listening
sudo netstat -tulpn | grep 8472

# Check firewall rules
sudo ufw status | grep 8472

# Solution: Allow Flannel VXLAN traffic (UDP port 8472) from LAN
sudo ufw allow from 192.168.0.0/16 to any port 8472 proto udp

# This rule is automatically added by setup-system.sh
# If you set up nodes manually, ensure this rule exists on ALL nodes
```

**Tailscale Connectivity**
```bash
# Check Tailscale status
sudo tailscale status

# Test VPS connectivity
ping 100.x.x.x  # VPS Tailscale IP

# Solution: Restart Tailscale or re-authenticate
sudo systemctl restart tailscaled
sudo tailscale up --authkey=<your-key>
```

### Storage and Persistence Issues

**Symptoms**
- Applications losing data after restart
- "No space left on device" errors
- Storage monitoring alerts

**Diagnosis**
```bash
# Check disk usage
df -h
du -sh /opt/k3s-storage/*
du -sh /media/data/*

# Check storage monitoring
./scripts/homelab.sh monitor status
journalctl -u storage-monitor --tail=20

# Check PV/PVC status
kubectl get pv
kubectl get pvc -A
kubectl describe pv <pv-name>
```

**Common Causes & Solutions**

**Disk Space Issues**
```bash
# Find large files
find /opt/k3s-storage -size +1G -type f
find /media/data -size +10G -type f

# Clean up logs
sudo journalctl --vacuum-time=7d
docker system prune -f

# Solution: Add storage or clean up files
# Move large files to external storage
# Increase retention policies
```

**Permission Issues**
```bash
# Check ownership
ls -la /opt/k3s-storage/
ls -la /media/data/

# Solution: Fix permissions
sudo chown -R $USER:$USER /media/data/
sudo chown -R $USER:$USER /opt/k3s-storage/
sudo chmod -R 755 /media/data/
```

**Mount Point Issues**
```bash
# Check mounted filesystems
mount | grep -E "(data|storage)"
lsblk

# Check for mount errors
dmesg | grep -i error

# Solution: Remount or fix filesystem
sudo umount /media/data
sudo fsck /dev/<device>
sudo mount /dev/<device> /media/data
```

**Storage Monitoring False Positives**
```bash
# Check monitoring configuration
cat config/service-configs/monitoring.conf

# Test monitoring manually
./scripts/monitor-storage.sh check

# Solution: Adjust monitoring sensitivity
nano config/service-configs/monitoring.conf
./scripts/homelab.sh monitor restart
```

## Infrastructure Issues

### K3s Cluster Problems

**Symptoms**
- kubectl commands failing
- Nodes showing as NotReady
- Cluster services not responding

**Diagnosis**
```bash
# Check K3s service
sudo systemctl status k3s
sudo journalctl -u k3s --tail=50

# Check cluster components
kubectl get componentstatuses
kubectl get nodes -o wide

# Check cluster networking
kubectl get pods -n kube-system
```

**Common Causes & Solutions**

**K3s Service Issues**
```bash
# Restart K3s service
sudo systemctl restart k3s

# Check for configuration errors
sudo cat /var/lib/rancher/k3s/server/logs/audit.log

# Solution: Reinstall K3s if corrupted
sudo /usr/local/bin/k3s-uninstall.sh
./scripts/homelab.sh setup-cluster
```

**Network Plugin Issues**
```bash
# Check Flannel pods
kubectl get pods -n kube-system | grep flannel

# Check CNI configuration
sudo cat /var/lib/rancher/k3s/agent/etc/cni/net.d/*

# Solution: Restart network components
kubectl delete pods -n kube-system -l app=flannel
```

**etcd/SQLite Issues**
```bash
# Check K3s datastore
sudo ls -la /var/lib/rancher/k3s/server/db/

# Check for corruption
sudo journalctl -u k3s | grep -i database

# Solution: Restore from backup or reinitialize
# (This requires careful backup/restore procedures)
```

### Tailscale Issues

**Symptoms**
- VPS cannot reach homelab
- Tailscale shows disconnected
- Network authentication failures

**Diagnosis**
```bash
# Check Tailscale daemon
sudo systemctl status tailscaled
sudo tailscale status

# Check connectivity
sudo tailscale ping <peer-name>
sudo tailscale netcheck

# Check authentication
sudo tailscale status | grep -i expired
```

**Common Causes & Solutions**

**Authentication Expired**
```bash
# Re-authenticate with new key
sudo tailscale up --authkey=<new-key>

# Force re-authentication
sudo tailscale logout
sudo tailscale up --authkey=<key>
```

**Network Connectivity**
```bash
# Check firewall rules
sudo ufw status
sudo iptables -L

# Reset Tailscale network
sudo tailscale down
sudo tailscale up --reset
```

**Version Conflicts**
```bash
# Update Tailscale
sudo tailscale update

# Check version compatibility
sudo tailscale version
```

### VPS Proxy Issues

**Symptoms**
- External access not working
- SSL errors from outside
- VPS returning 502/504 errors

**Diagnosis**
```bash
# On VPS: Check services
sudo systemctl status nginx tailscaled

# Check logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/stream_error.log

# Test connectivity to homelab
curl -I http://100.x.x.x  # Homelab Tailscale IP
```

**Common Causes & Solutions**

**Nginx Configuration Issues**
```bash
# Test nginx configuration
sudo nginx -t

# Reload configuration
sudo systemctl reload nginx

# Check proxy configuration
sudo cat /etc/nginx/conf.d/homelab-proxy.conf
```

**Tailscale Connectivity on VPS**
```bash
# Check VPS Tailscale status
sudo tailscale status

# Test connectivity to homelab
sudo tailscale ping homelab-hostname

# Solution: Restart Tailscale on VPS
sudo systemctl restart tailscaled
sudo tailscale up --authkey=<key>
```

## Application-Specific Issues

### Media Stack Issues

**Jellyfin Problems**
```bash
# Check Jellyfin logs
kubectl logs -n media deployment/jellyfin --tail=100

# Check media permissions
ls -la /media/data/media/

# Common issues:
# - Permission denied: Fix with chown/chmod
# - Transcoding failures: Check hardware acceleration
# - Database corruption: Restart service or restore backup
```

**Sonarr/Radarr Issues**
```bash
# Check application logs
kubectl logs -n media deployment/sonarr --tail=100

# Check download client connectivity
kubectl exec -it -n media deployment/sonarr -- curl http://qbittorrent:8080

# Common issues:
# - Indexer failures: Check Prowlarr configuration
# - Download client unreachable: Check network/credentials
# - Permission errors: Fix media folder permissions
```

**qBittorrent Issues**
```bash
# Check qBittorrent logs
kubectl logs -n media deployment/qbittorrent --tail=100

# Check download permissions
ls -la /media/data/downloads/

# Common issues:
# - Can't write to download directory: Fix permissions
# - Web UI inaccessible: Check service/ingress configuration
# - Torrents stuck: Check seeders/network connectivity
```

### Nextcloud Issues

**Database Connection Problems**
```bash
# Check PostgreSQL status
kubectl logs -n cloud deployment/postgres --tail=50

# Test database connectivity
kubectl exec -it -n cloud deployment/postgres -- \
  psql -U nextcloud -d nextcloud -c "SELECT version();"

# Solution: Restart database or fix credentials
kubectl rollout restart deployment/postgres -n cloud
```

**Storage Issues**
```bash
# Check Nextcloud data permissions
ls -la /opt/k3s-storage/nextcloud-files/

# Check disk space
df -h /opt/k3s-storage/

# Solution: Fix permissions or add storage
sudo chown -R 33:33 /opt/k3s-storage/nextcloud-files/
```

**Performance Issues**
```bash
# Check Redis cache
kubectl logs -n cloud deployment/redis --tail=50

# Check resource usage
kubectl top pods -n cloud

# Solution: Scale resources or optimize configuration
kubectl edit deployment nextcloud -n cloud
```

## Emergency Procedures

### Complete Service Failure

**Immediate Response**
```bash
# Check if it's a storage issue
./scripts/homelab.sh monitor status

# If storage failure detected:
./scripts/monitor-storage.sh stop-workloads

# Otherwise, check cluster health:
kubectl get nodes
kubectl get pods -A
```

**Recovery Steps**
```bash
# 1. Ensure cluster is healthy
sudo systemctl restart k3s
kubectl get nodes

# 2. Redeploy all applications
./scripts/homelab.sh deploy

# 3. Verify services
./scripts/homelab.sh status

# 4. Check data integrity
# Verify critical data is accessible
```

### Data Recovery

**From Recent Backup**
```bash
# Stop affected services
kubectl scale deployment --all -n <namespace> --replicas=0

# Restore data from backup
tar -xzf backup-$(date +%Y%m%d).tar.gz -C /

# Restart services
kubectl scale deployment --all -n <namespace> --replicas=1
```

**Partial Data Recovery**
```bash
# Restore specific service data
kubectl scale deployment/<service> -n <namespace> --replicas=0

# Copy data from backup
cp -r backup/opt/k3s-storage/<service>/ /opt/k3s-storage/

# Fix permissions
sudo chown -R $USER:$USER /opt/k3s-storage/<service>/

# Restart service
kubectl scale deployment/<service> -n <namespace> --replicas=1
```

### Network Isolation

**When External Access Fails**
```bash
# Access services locally via port-forward
kubectl port-forward -n media deployment/jellyfin 8096:8096

# Access via node IP
curl http://<node-ip>:<nodeport>

# Debug network step by step
# 1. Test pod to pod communication
# 2. Test service to service communication
# 3. Test ingress routing
# 4. Test external DNS/connectivity
```

## Prevention Strategies

### Monitoring Setup

```bash
# Set up automated health checks
crontab -e
# Add: */5 * * * * /home/user/homelab/scripts/homelab.sh status | grep -q "operational" || echo "Health check failed" | mail -s "Homelab Alert" admin@domain.com

# Verify Prometheus monitoring
cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom

# Set up log monitoring
journalctl -u k3s -f | grep -i error &
```

### Backup Verification

```bash
# Regular backup tests
./scripts/backup-notify.sh verify

# Test restore procedures monthly
# 1. Stop test service
# 2. Delete data
# 3. Restore from backup
# 4. Verify functionality
```

### Documentation

```bash
# Keep troubleshooting log
echo "$(date): Issue X resolved by doing Y" >> ~/homelab-issues.log

# Document custom configurations
# Update this file with new issues and solutions
```

## Getting Help

### Collecting Debug Information

```bash
# Generate comprehensive debug report
cat << EOF > homelab-debug-$(date +%Y%m%d).txt
=== System Information ===
$(uname -a)
$(df -h)
$(free -h)

=== Cluster Status ===
$(kubectl get nodes -o wide)
$(kubectl get pods -A)
$(kubectl get events --sort-by='.lastTimestamp' -A | tail -20)

=== Service Logs ===
$(kubectl logs -n kube-system deployment/traefik --tail=20)
$(kubectl logs -n media deployment/jellyfin --tail=20)

=== Network Status ===
$(sudo tailscale status)
$(ip route)
EOF
```

### Useful Resources

- **Kubernetes Documentation**: [kubernetes.io](https://kubernetes.io/docs/)
- **K3s Documentation**: [k3s.io](https://k3s.io/)
- **Traefik Documentation**: [doc.traefik.io](https://doc.traefik.io/)
- **Tailscale Documentation**: [tailscale.com/kb](https://tailscale.com/kb/)

Remember: Most issues can be resolved by restarting services, checking permissions, or verifying configuration. Always check logs first, and don't hesitate to restart components when troubleshooting.