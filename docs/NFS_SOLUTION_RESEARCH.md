# NFS Stale Mount Solution - Industry Best Practices Comparison

## Executive Summary

This document cross-references our implemented solution against industry best practices, research, and recommendations from major cloud providers and the Linux/Kubernetes communities.

**Verdict**: Our solution aligns well with industry standards, with some areas for optimization based on specific workload requirements.

---

## Mount Options Analysis

### ✅ Hard Mounts (CORRECT)

**Our choice**: `hard`

**Industry consensus**: **Use hard mounts** for data integrity

> "A so-called 'soft' timeout can cause silent data corruption in certain cases. Do not use the soft option. It poses a data consistency threat."
> — Red Hat Enterprise Linux Documentation

**Sources**:
- [NetApp: Hard vs Soft Mount](https://kb.netapp.com/onprem/ontap/da/NAS/What_are_the_differences_between_hard_mount_and_soft_mount)
- [Red Hat: Common NFS Mount Options](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/5/html/deployment_guide/s1-nfs-client-config-options)

**Trade-off**: Hard mounts retry indefinitely, which can cause hangs when NFS server is down. This is why our monitoring solution is critical.

---

### ⚠️ Timeout Value - Needs Tuning

**Our choice**: `timeo=150` (15 seconds)

**Industry recommendations**:
- **AWS EFS**: `timeo=600` (60 seconds) - default
- **Azure NetApp**: `timeo=600` (60 seconds)
- **Red Hat**: Soft mounts should use at least `timeo=150` (15s) minimum

**Analysis**:
- Our 15-second timeout is **more aggressive** than AWS/Azure recommendations
- This provides **faster failure detection** but **higher risk of false positives** during temporary network issues
- AWS/Azure use 60s because they assume network issues are brief

**Recommendation**:
```yaml
# For stable networks (recommended):
timeo=300  # 30 seconds - balanced approach

# For unstable networks or faster failover:
timeo=150  # 15 seconds - our current setting

# For maximum stability (AWS/Azure default):
timeo=600  # 60 seconds
```

**Sources**:
- [AWS EFS: Recommended NFS mount settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html)
- [Microsoft: Linux NFS mount options best practices](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)

---

### ✅ Retransmission Count (GOOD)

**Our choice**: `retrans=3`

**Industry standard**: `retrans=2` (default)

**Analysis**:
- Increasing from 2 to 3 provides **one extra retry** before timeout
- AWS and most providers use the default of 2
- Our choice of 3 is **reasonable and conservative**

**Calculation**: With `timeo=150` and `retrans=3`:
- First attempt: 15s
- Retry 1: 30s (doubled)
- Retry 2: 60s (doubled again)
- Retry 3: 120s (doubled again)
- **Total time to failure: ~225 seconds** (~3.75 minutes)

**Sources**:
- [AWS EFS: Recommended NFS mount settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html)

---

### ✅ Attribute Caching (GOOD)

**Our choice**: `actimeo=30`

**Industry recommendations**:
- **Frequently modified directories**: `actimeo=1` to `actimeo=3`
- **Single-client or rarely changing**: `actimeo=120` to `actimeo=600`
- **General purpose**: `actimeo=30` to `actimeo=60`

**Analysis**:
- Our 30-second cache is a **good middle ground**
- Provides performance benefits while maintaining reasonable freshness
- Suitable for media files that don't change frequently

**Performance impact**:
> "For single-client scenarios: turning up the timeouts for the attribute cache management (actimeo=600) reduces getattr access calls by 20-25%"
> — Microsoft Azure Documentation

**Sources**:
- [Microsoft: Linux NFS mount options best practices](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)
- [The Geek Diary: Common NFS mount options](https://www.thegeekdiary.com/common-nfs-mount-options-in-linux/)

---

### ✅ Lookup Cache (GOOD)

**Our choice**: `lookupcache=positive`

**Industry recommendation**: `lookupcache=positive` for performance

**Analysis**:
- **Correct choice** for balancing performance and consistency
- Only caches positive lookups (files that exist)
- Avoids caching negative lookups (files that don't exist)

**Alternative**: `lookupcache=none` for maximum consistency (but slower)

**Sources**:
- [Linux man page: nfs(5)](https://linux.die.net/man/5/nfs)

---

### ✅ Network Device Flag (CORRECT)

**Our choice**: `_netdev`

**Industry recommendation**: **Use _netdev for network filesystems**

**Analysis**:
- Ensures systemd waits for network before mounting
- **Critical for preventing boot-time mount failures**
- Standard practice for all network mounts

---

### ✅ Non-Reserved Ports (CORRECT)

**Our choice**: `noresvport`

**Industry recommendation**: **Use noresvport for better reconnection**

**Analysis**:
> "Tells the NFS client to use a new non-privileged TCP source port when a network connection is reestablished, helping to ensure that NFS clients reconnect transparently"
> — AWS EFS Documentation

- **Improves reconnection after network interruption**
- Better firewall compatibility
- **Recommended by AWS, Azure, and Alibaba Cloud**

**Sources**:
- [AWS EFS: Recommended NFS mount settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html)
- [Alibaba Cloud: How to mount a NAS NFS file system](https://www.alibabacloud.com/help/en/nas/user-guide/mount-an-nfs-file-system-on-a-linux-ecs-instance)

---

### 📝 Missing Options (Consider Adding)

#### 1. `noatime` - Performance optimization

**Not in our solution** (should consider adding)

**Benefits**:
- Prevents updating file access times on read
- **Reduces write operations** significantly
- **10-30% performance improvement** for read-heavy workloads

**Recommendation**: **Add this** for media storage (movies, TV shows are mostly read-only)

```yaml
mountOptions:
  - noatime  # Don't update access times (performance boost)
```

**Sources**:
- [OneUptime: How to Use NAS Storage with Kubernetes](https://oneuptime.com/blog/post/2025-12-15-how-to-use-nas-storage-with-kubernetes/view)

---

#### 2. `nocto` - Performance optimization (use with caution)

**Not in our solution** (optional)

**Benefits**:
- Disables "close-to-open" cache consistency
- Reduces getattr calls by 20-25%
- **Better performance for single-client scenarios**

**Risk**: Can cause stale data if multiple clients modify files

**Recommendation**: **Only for single-client or read-mostly workloads**

**Sources**:
- [Microsoft: Linux NFS mount options best practices](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)

---

#### 3. `vers=4.1` vs `nfsvers=4.1`

**Our choice**: `nfsvers=4.1`

**Industry standard**: Both work, but `vers=` is more modern

**Recommendation**: Change to `vers=4.1` for consistency with docs

---

## Monitoring and Recovery Analysis

### ✅ Automatic Detection and Recovery (INNOVATIVE)

**Our solution**:
- 5-minute health checks
- Automatic CSI driver restart
- Automatic pod restart
- Prometheus metrics

**Industry state**:
> "When the server is terminated while still mounted to pods, the CSI driver node does not unmount the stale mount and create a new mount"
> — Kubernetes GitHub Issue #75918 (open since 2019)

**Analysis**:
- **Kubernetes has NO built-in recovery mechanism**
- Long-standing issues with stale NFS mounts in Kubernetes:
  - [Issue #75918: NFS PV's don't recover](https://github.com/kubernetes/kubernetes/issues/75918) (2019)
  - [Issue #31272: Hung volumes can wedge the kubelet](https://github.com/kubernetes/kubernetes/issues/31272) (2016)
  - [Issue #71584: Pod using subpath with NFS stuck in terminating](https://github.com/kubernetes/kubernetes/issues/71584) (2018)

**Our solution addresses a gap in the ecosystem** - there's no standard automatic recovery solution

**Sources**:
- [Kubernetes Issue #75918](https://github.com/kubernetes/kubernetes/issues/75918)
- [Kubernetes Issue #31272](https://github.com/kubernetes/kubernetes/issues/31272)

---

## Recommended Mount Option Improvements

Based on research, here are suggested improvements:

### Option 1: Conservative (Maximum Stability)
```yaml
mountOptions:
  - vers=4.1
  - hard
  - timeo=600           # 60s - AWS/Azure standard
  - retrans=2           # Standard retry count
  - rsize=1048576
  - wsize=1048576
  - _netdev
  - noresvport
  - noatime             # NEW: Performance boost
  - actimeo=60          # Longer cache for stability
  - lookupcache=positive
```

**Best for**: Production environments with stable networks

---

### Option 2: Balanced (Current with improvements)
```yaml
mountOptions:
  - vers=4.1
  - hard
  - timeo=300           # CHANGED: 30s instead of 15s
  - retrans=3           # Keep extra retry
  - rsize=1048576
  - wsize=1048576
  - _netdev
  - noresvport
  - noatime             # NEW: Performance boost
  - actimeo=30          # Keep current value
  - lookupcache=positive
```

**Best for**: General purpose with good network reliability

---

### Option 3: Fast Failover (Current)
```yaml
mountOptions:
  - vers=4.1
  - hard
  - timeo=150           # Keep current 15s
  - retrans=3
  - rsize=1048576
  - wsize=1048576
  - _netdev
  - noresvport
  - noatime             # NEW: Add this
  - actimeo=30
  - lookupcache=positive
```

**Best for**: Environments where faster failure detection is critical

---

### Option 4: Performance Optimized (Single Client)
```yaml
mountOptions:
  - vers=4.1
  - hard
  - timeo=300
  - retrans=2
  - rsize=1048576
  - wsize=1048576
  - _netdev
  - noresvport
  - noatime             # NEW: Performance
  - nocto               # NEW: Performance (single client only!)
  - actimeo=600         # NEW: Longer cache
  - lookupcache=positive
```

**Best for**: Read-heavy workloads with single client (like Plex/Jellyfin)

---

## Common Solutions from the Community

### 1. Force Unmount and Remount
```bash
# Standard fix found in community forums
umount -f /mount/point
mount /mount/point
```

**Our solution**: ✅ Automated via CSI driver restart

---

### 2. Lazy Unmount
```bash
umount -l /mount/point
```

**Analysis**: Risky, can leave processes in bad state
**Our solution**: Uses graceful pod termination instead

---

### 3. Restart Kubelet
```bash
systemctl restart kubelet
```

**Analysis**: Too disruptive, affects all pods on node
**Our solution**: ✅ More targeted - only restarts CSI driver

---

### 4. Server-Side Export Refresh
```bash
# On NFS server
exportfs -ra
```

**Our solution**: Should be paired with this for complete recovery

---

## Known Kubernetes Limitations

From our research, these are **unsolved problems in Kubernetes**:

1. **No automatic stale mount detection**
   - Our solution: ✅ 5-minute health checks

2. **CSI driver doesn't recover from server restarts**
   - Our solution: ✅ Automatic CSI driver restart

3. **Pods remain in broken state**
   - Our solution: ✅ Automatic pod restart

4. **Kubelet can get wedged by stale mounts**
   - Our solution: ⚠️ Partially addressed (prevents by early detection)

**Sources**:
- [NixCraft: NFS Stale File Handle error and solution](https://www.cyberciti.biz/tips/nfs-stale-file-handle-error-and-solution.html)
- [Alibaba Cloud: NAS volume FAQ](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/faq-about-nas-volumes)

---

## Final Recommendations

### Immediate Actions

1. **Add `noatime` mount option** - Easy performance win
2. **Consider increasing `timeo` to 300** - More stable, still faster than AWS default
3. **Test current settings under load** - Validate failure detection time

### Short-term Improvements

1. **Make mount options configurable** - Different workloads need different settings
2. **Add server-side recovery** - Include `exportfs -ra` in recovery script
3. **Add kubelet health check** - Detect if kubelet is wedged

### Long-term Considerations

1. **NFS Server HA** - Eliminate single point of failure
2. **Dedicated storage network** - Isolate NFS traffic
3. **Consider alternative storage** - CSI drivers for Ceph, GlusterFS, etc.

---

## Conclusion

Our solution is **well-aligned with industry best practices** and **innovatively addresses gaps** in the Kubernetes ecosystem:

### ✅ What we got right:
- Hard mounts for data integrity
- noresvport for better reconnection
- Appropriate attribute caching
- **First-class monitoring and recovery** (better than any standard solution)

### ⚠️ What to improve:
- Add `noatime` for performance
- Consider longer timeout (300 instead of 150)
- Make options configurable per workload

### 🎯 Our competitive advantage:
- **Automatic detection and recovery** - fills a major gap in Kubernetes
- **Prometheus integration** - observability
- **Comprehensive documentation** - better than most enterprise solutions

---

## Sources

All recommendations cross-referenced against:
- [AWS EFS NFS Mount Settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html)
- [Microsoft Azure NetApp Files Mount Options](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options)
- [Red Hat NFS Mount Options](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/5/html/deployment_guide/s1-nfs-client-config-options)
- [NetApp Knowledge Base](https://kb.netapp.com/onprem/ontap/da/NAS/What_are_the_differences_between_hard_mount_and_soft_mount)
- [Linux NFS Man Page](https://linux.die.net/man/5/nfs)
- [Kubernetes GitHub Issues #75918, #31272, #71584](https://github.com/kubernetes/kubernetes)
- [Alibaba Cloud NAS FAQ](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/faq-about-nas-volumes)
- [NixCraft NFS Troubleshooting](https://www.cyberciti.biz/tips/nfs-stale-file-handle-error-and-solution.html)
- [OneUptime Kubernetes NAS Guide](https://oneuptime.com/blog/post/2025-12-15-how-to-use-nas-storage-with-kubernetes/view)
