# NFS Stale Mount Prevention and Recovery

## Problem

Stale NFS mounts occur when:
- NFS server restarts or reboots
- Network interruptions between client and server
- Long timeouts with hard mounts cause system hangs
- No automatic recovery mechanism exists

## Solution Overview

This solution implements a **multi-layered defense** against stale NFS mounts:

1. **Improved mount options** - Faster failure detection and better resilience
2. **Active monitoring** - Detects stale mounts automatically
3. **Automatic recovery** - Restarts CSI driver and affected pods
4. **Prometheus metrics** - Visibility and alerting

## Components

### 1. Improved NFS Mount Options

**File**: `cluster/infrastructure/storage/nfs-storageclass.yaml`

**Key changes**:
- `timeo=150` (15s instead of 60s) - Faster failure detection
- `retrans=3` (up from 2) - More retry attempts
- `actimeo=30` - Better attribute caching
- `_netdev` - Ensures proper mount ordering
- `noresvport` - Better firewall compatibility
- `lookupcache=positive` - Optimized lookup caching

**Trade-offs**:
- Still uses `hard` mounts for data consistency
- Shorter timeout means faster detection but potentially more false positives during network hiccups
- More retries provide better resilience

### 2. NFS Health Monitoring Script

**File**: `scripts/monitor-nfs-health.sh`

**Features**:
- Checks NFS server connectivity (port 2049)
- Scans all kubelet NFS CSI mounts for staleness
- Automatically restarts CSI driver when issues detected
- Restarts affected pods if CSI restart insufficient
- Exports Prometheus metrics
- Logging and state tracking

**Usage**:
```bash
# Run health check (with auto-recovery)
./scripts/monitor-nfs-health.sh check

# Show current status
./scripts/monitor-nfs-health.sh status

# Manual recovery
./scripts/monitor-nfs-health.sh recover
```

### 3. Automated Monitoring

**Option A: systemd Timer (Storage Node)**

Install on the storage node (cyl-homelab):

```bash
# Install the systemd timer
sudo cp /home/cyl/homelab/config/systemd/nfs-monitor.{timer,service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nfs-monitor.timer

# Verify
systemctl list-timers nfs-monitor.timer
systemctl status nfs-monitor.service
```

This runs every 5 minutes and:
- Checks for stale mounts
- Attempts automatic recovery
- Logs to `/var/log/nfs-health-monitor.log`
- Exports metrics to `/var/lib/node_exporter/textfile_collector/nfs_health.prom`

**Option B: Kubernetes DaemonSet**

Deploy the monitoring DaemonSet to all nodes:

```bash
kubectl apply -f cluster/applications/monitoring/nfs-health-monitor.yaml
```

This creates a DaemonSet that:
- Runs on every node
- Continuously monitors NFS mounts (every 5 minutes)
- Logs stale mount detection
- Low resource usage (10m CPU, 32Mi RAM)

### 4. Prometheus Metrics

The monitoring script exports these metrics:

```prometheus
# Overall health
nfs_health_status{type="overall"} 1

# NFS server connectivity
nfs_server_reachable{server="192.168.1.94"} 1

# Mount health
nfs_mounts_healthy 1

# Counters
nfs_stale_mounts_detected_total 0
nfs_recovery_attempts_total 0
nfs_recovery_successes_total 0
nfs_monitor_last_run_timestamp_seconds 1703376000
```

**Alert rules** (add to Prometheus):

```yaml
groups:
  - name: nfs_health
    interval: 30s
    rules:
      - alert: NFSServerUnreachable
        expr: nfs_server_reachable == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "NFS server {{ $labels.server }} is unreachable"
          description: "The NFS server has been unreachable for more than 2 minutes"

      - alert: NFSStaleMountsDetected
        expr: nfs_mounts_healthy == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Stale NFS mounts detected"
          description: "One or more NFS mounts have become stale. Auto-recovery should be in progress."

      - alert: NFSRecoveryFailing
        expr: increase(nfs_recovery_attempts_total[10m]) > 3 and increase(nfs_recovery_successes_total[10m]) == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "NFS automatic recovery is failing"
          description: "Multiple recovery attempts have failed. Manual intervention required."
```

## Deployment Steps

### Step 1: Update NFS StorageClass

```bash
# Review the changes
git diff cluster/infrastructure/storage/nfs-storageclass.yaml

# Apply the updated StorageClass
kubectl apply -f cluster/infrastructure/storage/nfs-storageclass.yaml
```

**Note**: Existing PVs will keep their old mount options. To apply new options:

**Option 1**: Recreate PVs (requires downtime)
```bash
# For each PV, delete and recreate
kubectl delete pv <pv-name>
kubectl apply -f cluster/applications/<namespace>/storage/<pv-file>.yaml
```

**Option 2**: Manual remount (no downtime, temporary)
```bash
# The new options will apply to new PVs automatically
# Existing mounts will update when pods restart
```

### Step 2: Deploy Monitoring Script

```bash
# Make the script executable
chmod +x scripts/monitor-nfs-health.sh

# Test it manually
sudo ./scripts/monitor-nfs-health.sh check

# Check status
sudo ./scripts/monitor-nfs-health.sh status

# View logs
sudo tail -f /var/log/nfs-health-monitor.log
```

### Step 3: Enable Automated Monitoring

Choose one approach:

**A. systemd Timer (recommended for storage node)**
```bash
# Install timer and service files
sudo cp /home/cyl/homelab/config/systemd/nfs-monitor.{timer,service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nfs-monitor.timer
```

**B. DaemonSet (recommended for multi-node cluster)**
```bash
kubectl apply -f cluster/applications/monitoring/nfs-health-monitor.yaml

# Check status
kubectl get pods -n kube-system -l app=nfs-health-monitor
kubectl logs -n kube-system -l app=nfs-health-monitor
```

### Step 4: Configure Prometheus (Optional)

```bash
# Add alert rules to Prometheus
kubectl edit prometheusrule -n monitoring kube-prometheus-stack-alertmanager.rules

# Add the alert rules from above
```

## Testing

### Test 1: Simulate NFS Server Restart

```bash
# On storage node
sudo systemctl restart nfs-server

# Watch monitoring logs
sudo tail -f /var/log/nfs-health-monitor.log

# Check if recovery happens automatically
kubectl get pods -A -w
```

### Test 2: Simulate Network Issue

```bash
# On storage node, temporarily block NFS port
sudo iptables -A INPUT -p tcp --dport 2049 -j DROP
sudo iptables -A OUTPUT -p tcp --dport 2049 -j DROP

# Wait for detection (up to 5 minutes)
sudo ./scripts/monitor-nfs-health.sh check

# Restore connectivity
sudo iptables -D INPUT -p tcp --dport 2049 -j DROP
sudo iptables -D OUTPUT -p tcp --dport 2049 -j DROP
```

### Test 3: Manual Stale Mount

```bash
# Find a NFS mount
mount | grep nfs

# Force unmount on server side (creates stale mount on client)
# On storage node:
sudo exportfs -ua
sleep 2
sudo exportfs -ra

# Check detection
sudo ./scripts/monitor-nfs-health.sh check
```

## Troubleshooting

### Issue: Monitoring script fails

```bash
# Check dependencies
which kubectl stat timeout

# Check permissions
ls -la /var/lib/kubelet/pods/

# Run with debug
bash -x ./scripts/monitor-nfs-health.sh check
```

### Issue: CSI driver won't restart

```bash
# Check CSI driver status
kubectl get pods -n kube-system -l app=csi-nfs-node

# Manually delete pods
kubectl delete pods -n kube-system -l app=csi-nfs-node

# Check for errors
kubectl logs -n kube-system -l app=csi-nfs-node -c nfs
```

### Issue: Pods won't restart

```bash
# Check pod status
kubectl get pods -A | grep -v Running

# Describe stuck pods
kubectl describe pod -n <namespace> <pod-name>

# Force delete if needed
kubectl delete pod -n <namespace> <pod-name> --grace-period=0 --force
```

### Issue: Metrics not appearing

```bash
# Check metrics file
cat /var/lib/node_exporter/textfile_collector/nfs_health.prom

# Verify Prometheus scraping
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Visit http://localhost:9090 and query: nfs_health_status
```

## Prevention Best Practices

1. **NFS Server Stability**
   - Ensure NFS server has reliable power (UPS)
   - Monitor NFS server health
   - Plan maintenance windows for restarts

2. **Network Reliability**
   - Use dedicated network for storage (if possible)
   - Monitor network connectivity
   - Ensure proper switch configuration

3. **Monitoring**
   - Set up Prometheus alerts
   - Monitor recovery success rate
   - Review logs regularly

4. **Regular Testing**
   - Test NFS server failover quarterly
   - Verify automatic recovery works
   - Update runbooks based on findings

## Additional Improvements (Future)

1. **NFS Server HA**: Deploy redundant NFS servers with failover
2. **Better mount options**: Consider `soft` mounts for non-critical data
3. **Autofs**: Use autofs for automatic remounting
4. **ReadWriteMany optimization**: Use proper file locking for RWX volumes
5. **CSI driver tuning**: Adjust CSI driver resource limits and timeouts

## References

- [NFS Client Mount Options](https://linux.die.net/man/5/nfs)
- [Kubernetes CSI Driver NFS](https://github.com/kubernetes-csi/csi-driver-nfs)
- [NFSv4 Best Practices](https://wiki.linux-nfs.org/wiki/index.php/NFS4_Best_Practices)

## Maintenance

### Weekly
- Review `/var/log/nfs-health-monitor.log`
- Check Prometheus metrics for trends

### Monthly
- Test manual recovery: `./scripts/monitor-nfs-health.sh recover`
- Review and clean up old logs

### Quarterly
- Review mount options for optimization
- Test NFS server failover scenario
- Update documentation based on learnings
