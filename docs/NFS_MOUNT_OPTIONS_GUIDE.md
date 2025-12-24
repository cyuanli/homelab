# NFS Mount Options Selection Guide

## Quick Reference

| StorageClass | Use Case | Failover Time | Performance | Risk |
|--------------|----------|---------------|-------------|------|
| `nfs-media-optimized` | **General purpose (recommended)** | ~1-2 min | High | Low |
| `nfs-media-stable` | Production, critical data | ~3-4 min | Good | Very Low |
| `nfs-media-performance` | Read-heavy, single client (Jellyfin) | ~1-2 min | Highest | Low* |
| `nfs-media-fastfail` | Fast failure detection needed | ~30-45 sec | High | Medium |

*Only use `nfs-media-performance` for read-mostly workloads with a single client

---

## Available StorageClasses

All configurations are available in: `cluster/infrastructure/storage/nfs-storageclass-optimized.yaml`

### 1. nfs-media-optimized (RECOMMENDED)

**Best for**: General purpose NFS storage

**Mount options**:
```yaml
timeo=300      # 30 second timeout (balanced)
retrans=3      # 3 retries for resilience
noatime        # Performance optimization
actimeo=30     # 30 second attribute cache
```

**Characteristics**:
- ✅ Balanced between speed and stability
- ✅ 10-30% performance boost from `noatime`
- ✅ Reasonable failover time (~1-2 minutes)
- ✅ Based on industry best practices from AWS, Azure, Red Hat

**Total failover time calculation**:
- Attempt 1: 30s
- Retry 1: 60s (timeout doubles)
- Retry 2: 120s (timeout doubles again)
- **Total: ~3.5 minutes** to declare failure

**When to use**:
- Media storage (movies, TV, music)
- General application data
- Any workload where 2-3 minute recovery is acceptable

---

### 2. nfs-media-stable

**Best for**: Maximum stability and data integrity

**Mount options**:
```yaml
timeo=600      # 60 second timeout (AWS/Azure standard)
retrans=2      # Standard retry count
noatime        # Performance optimization
actimeo=60     # 60 second attribute cache
```

**Characteristics**:
- ✅ Matches AWS EFS and Azure NetApp Files defaults
- ✅ Lowest risk of false positives during network blips
- ✅ Maximum data integrity
- ⚠️ Slower failure detection (3-4 minutes)

**Total failover time calculation**:
- Attempt 1: 60s
- Retry 1: 120s
- Retry 2: 240s
- **Total: ~7 minutes** to declare failure

**When to use**:
- Critical production data
- Database storage (if using NFS)
- Any workload where stability > speed
- Networks with occasional brief interruptions

---

### 3. nfs-media-performance

**Best for**: Read-heavy workloads with single client

**Mount options**:
```yaml
timeo=300      # 30 second timeout
retrans=2      # Standard retries
noatime        # Don't track access times
nocto          # Disable close-to-open consistency
actimeo=600    # 10 minute attribute cache
```

**Characteristics**:
- ✅ Highest performance (20-30% improvement)
- ✅ Reduced NFS protocol overhead
- ⚠️ **Only safe for single-client scenarios**
- ⚠️ Can serve stale data if multiple clients modify files

**When to use**:
- Jellyfin/Plex media libraries (read-only access)
- Backup storage (single writer)
- Archive/cold storage
- Any read-heavy, single-client workload

**WARNING**: Do NOT use for:
- Multi-writer scenarios (qBittorrent, Sonarr, Radarr all writing)
- Database storage
- Shared configuration files

---

### 4. nfs-media-fastfail

**Best for**: Environments requiring fast failure detection

**Mount options**:
```yaml
timeo=150      # 15 second timeout (aggressive)
retrans=3      # 3 retries to compensate
noatime        # Performance optimization
actimeo=30     # 30 second attribute cache
```

**Characteristics**:
- ✅ Fastest failure detection (~30-45 seconds)
- ✅ Quick recovery in automated monitoring
- ⚠️ Higher risk of false positives during network issues
- ⚠️ May trigger unnecessary recoveries

**Total failover time calculation**:
- Attempt 1: 15s
- Retry 1: 30s
- Retry 2: 60s
- Retry 3: 120s
- **Total: ~3.75 minutes** to declare failure

**When to use**:
- Unstable networks where you want fast detection
- Testing/development environments
- When paired with our automatic recovery solution
- Environments where occasional false alarms are acceptable

---

## Migration Guide

### Current Setup

Your current StorageClass (`nfs-media`) uses:
```yaml
timeo=150
retrans=3
(missing noatime)
actimeo=30
```

This is equivalent to **nfs-media-fastfail** but without the `noatime` optimization.

### Recommended Migration Path

**Step 1**: Deploy new StorageClasses (no downtime)
```bash
kubectl apply -f cluster/infrastructure/storage/nfs-storageclass-optimized.yaml
```

**Step 2**: Choose your target StorageClass

For most users, we recommend **nfs-media-optimized**:
- Better stability than current (30s timeout vs 15s)
- Performance boost from `noatime`
- Aligned with industry standards

**Step 3**: Update PVs to use new StorageClass

**Option A**: Update existing PVs (edit each PV)
```bash
# List all NFS PVs
kubectl get pv | grep nfs-media

# Edit each PV to change storageClassName
kubectl edit pv <pv-name>

# Change: storageClassName: nfs-media
# To:     storageClassName: nfs-media-optimized
```

**Option B**: Create new PVs with new StorageClass
```bash
# For new volumes, use the new StorageClass in your PV definitions
```

**Step 4**: Remount for options to take effect

Mount options only apply when volumes are mounted. To apply new options:

```bash
# Restart deployments to remount with new options
kubectl rollout restart deployment -n media jellyfin
kubectl rollout restart deployment -n media sonarr
kubectl rollout restart deployment -n media radarr
# ... etc
```

**Step 5**: Update current StorageClass (optional)

If you want to update the existing `nfs-media` StorageClass:
```bash
# Backup current
kubectl get storageclass nfs-media -o yaml > /tmp/nfs-media-backup.yaml

# Delete old
kubectl delete storageclass nfs-media

# Apply optimized as the default
cp cluster/infrastructure/storage/nfs-storageclass-optimized.yaml /tmp/new-default.yaml
# Edit /tmp/new-default.yaml and change name to 'nfs-media'
kubectl apply -f /tmp/new-default.yaml
```

---

## Performance Comparison

Based on Microsoft Azure NetApp Files benchmarks:

| Option | Getattr Calls | Performance Impact |
|--------|---------------|-------------------|
| Default | Baseline | 0% |
| `noatime` | -15% | +10-30% throughput |
| `actimeo=600` | -20% | +15-25% throughput |
| `nocto` | -25% | +20-30% throughput |
| **All combined** | **-60%** | **+40-50% throughput** |

**Source**: [Microsoft: Linux NFS mount options best practices](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)

---

## Workload Recommendations

### Media Stack (Jellyfin, Plex)
**Recommended**: `nfs-media-performance`
- Read-heavy workload
- Single client per media file
- Large files, sequential access
- Maximum benefit from caching

### *arr Stack (Sonarr, Radarr, Prowlarr)
**Recommended**: `nfs-media-optimized`
- Multiple writers (qBittorrent + *arr apps)
- Need consistency between apps
- Can't use `nocto`

### qBittorrent Downloads
**Recommended**: `nfs-media-optimized` or `nfs-media-stable`
- Heavy write workload
- Important data (don't want corruption)
- Benefit from `noatime`

### Nextcloud Files
**Recommended**: `nfs-media-stable`
- Critical user data
- Multiple clients
- Needs maximum consistency
- Prioritize stability over speed

### Immich Photos
**Recommended**: `nfs-media-stable`
- Critical user photos
- Multiple users/clients
- Needs data integrity
- Accept slower failover for safety

### Monitoring (Prometheus, Grafana)
**Recommended**: `nfs-media-optimized`
- Time-series data (write-heavy)
- Can tolerate brief data loss
- Faster recovery preferred

### Game Servers (Minecraft backups)
**Recommended**: `nfs-media-optimized`
- Periodic writes
- Read-heavy (restore backups)
- Fast recovery helpful

---

## Testing Your Configuration

### Test 1: Measure Failover Time

```bash
# Terminal 1: Monitor a file on NFS mount
while true; do
  stat /path/to/nfs/mount/testfile
  echo "$(date): Mount accessible"
  sleep 1
done

# Terminal 2: Restart NFS server
sudo systemctl restart nfs-server

# Observe: How long until client detects failure?
```

### Test 2: Benchmark Performance

```bash
# Test write performance
dd if=/dev/zero of=/nfs/mount/testfile bs=1M count=1000 oflag=direct

# Test read performance
dd if=/nfs/mount/testfile of=/dev/null bs=1M iflag=direct

# Compare with different mount options
```

### Test 3: Check Attribute Cache Effectiveness

```bash
# Before optimization
time ls -l /nfs/mount/large/directory

# After adding actimeo=600
time ls -l /nfs/mount/large/directory  # Should be much faster on second run
```

---

## Troubleshooting

### Mount options not applying

**Symptom**: Changed StorageClass but still seeing old mount options

**Solution**:
```bash
# Check current mount options
mount | grep nfs | grep /var/lib/kubelet

# Mount options only apply on new mounts
# Restart pods to remount
kubectl rollout restart deployment -n <namespace> <deployment>
```

### Performance not improving

**Symptom**: Added `noatime` and `nocto` but no performance change

**Check**:
```bash
# Verify mount options are active
mount | grep nfs

# Should see: noatime,nocto in options

# If not, remount required
```

### Frequent disconnections with fastfail

**Symptom**: Using `nfs-media-fastfail` but getting too many false alarms

**Solution**: Switch to `nfs-media-optimized` (30s timeout) or `nfs-media-stable` (60s timeout)

---

## References

- [AWS EFS: Recommended NFS mount settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html)
- [Microsoft: Linux NFS mount options best practices](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)
- [Red Hat: Common NFS Mount Options](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/5/html/deployment_guide/s1-nfs-client-config-options)
- [Linux man page: nfs(5)](https://linux.die.net/man/5/nfs)
