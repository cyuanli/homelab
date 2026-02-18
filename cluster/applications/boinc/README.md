# BOINC Scientific Computing

BOINC (Berkeley Open Infrastructure for Network Computing) clients deployed across the K3s cluster as low-priority background workloads to contribute idle computing power to scientific research projects.

## Architecture

### DaemonSet with Node-Type Overlays

BOINC runs as **DaemonSets** with **Kustomize overlays** per node tier:

- **xlarge** (cyl-mitx): 12 cores, 16GB RAM → 500m CPU request, 12Gi memory limit
- **highmem** (cyl-aspiree17): 4 cores, 16GB RAM → 500m CPU request, 12Gi memory limit
- **highcpu** (cyl-xps13): 8 cores, 8GB RAM → 500m CPU request, 6Gi memory limit
- **standard** (cyl-inspiron14, cyl-yoga213): 4 cores, 8GB RAM → 500m CPU request, 6Gi memory limit

### Resource Management Strategy

**CPU**: No limits, 500m requests → enables CFS proportional sharing. BOINC uses idle CPU but yields to production workloads that request resources.

**Memory**: LXCFS provides container-aware `/proc/meminfo` so BOINC sees actual Kubernetes memory limits (6Gi or 12Gi) instead of host memory. BOINC's built-in memory management (80% busy, 90% idle) automatically stays within limits.

**Priority**: `low-priority-preemptible` class ensures BOINC pods are evicted first when cluster resources are needed.

## LXCFS Integration

**Problem**: BOINC reads `/proc/meminfo` which shows host memory, not container limits, causing OOM kills.

**Solution**: [LXCFS](https://github.com/lxc/lxcfs) (Linux Containers FileSystem) provides virtualized `/proc` files that respect cgroup limits.

**Implementation**:
1. LXCFS installed on agent nodes (via `ansible/playbooks/docker.yml`)
2. BOINC pods mount `/var/lib/lxcfs/proc/meminfo`, `/proc/cpuinfo`, `/proc/stat`, `/proc/uptime`
3. BOINC automatically detects correct container memory limits and manages resources accordingly

## Projects Contributing To

1. **Einstein@Home** - Gravitational wave detection
2. **World Community Grid** - Clean energy, medical research
3. **DENIS@home** - Discovering brown dwarfs and exoplanets
4. **Milkyway@Home** - Milky Way galaxy modeling
5. **SiDock@home** - Drug discovery through molecular docking
6. **Asteroids@home** - Asteroid shape and spin modeling
7. **Yoyo@home** - Mathematics and evolution research
8. **Climateprediction.net** - Climate modeling

## Management

### Deploy
```bash
# Deploy all overlays
kubectl apply -k cluster/applications/boinc/overlays/xlarge
kubectl apply -k cluster/applications/boinc/overlays/highmem
kubectl apply -k cluster/applications/boinc/overlays/highcpu
kubectl apply -k cluster/applications/boinc/overlays/standard
```

### Monitor
```bash
# Check pod status
kubectl get pods -n boinc -o wide

# View logs
kubectl logs -n boinc -l app=boinc-client

# Check resource usage
kubectl top pods -n boinc

# Check for OOM kills
kubectl get pods -n boinc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

### BOINC Commands
```bash
# Check project status
kubectl exec -n boinc <pod-name> -- boinccmd --get_project_status

# Check current tasks
kubectl exec -n boinc <pod-name> -- boinccmd --get_tasks

# Check host info (verify LXCFS is working)
kubectl exec -n boinc <pod-name> -- boinccmd --get_host_info | grep "mem size"

# Verify container sees correct memory limit
kubectl exec -n boinc <pod-name> -- cat /proc/meminfo | grep MemTotal
```

## Configuration Files

- **base/daemonset.yaml** - Base DaemonSet with LXCFS mounts
- **base/configmap.yaml** - BOINC client configuration (CPU 75%, memory 80%/90%)
- **base/secrets.yaml.template** - Project authentication keys
- **overlays/*/resources.yaml** - Per-tier resource limits
- **overlays/*/node-selector.yaml** - Node type selectors

## Troubleshooting

### OOM Kills
If BOINC pods show OOM kills despite LXCFS:
1. Verify LXCFS is running: `systemctl status lxcfs`
2. Check BOINC sees correct memory: `kubectl exec -n boinc <pod> -- cat /proc/meminfo | grep MemTotal`
3. Expected values: 6Gi ≈ 5.9GB, 12Gi ≈ 11.9GB

### High CPU Usage
BOINC is designed to use all idle CPU. This is expected behavior. Production workloads with CPU requests will preempt BOINC's CPU usage through CFS proportional sharing.

### Pod Not Scheduling
Check node allocatable memory: `kubectl describe node <node-name> | grep Allocatable -A 5`

BOINC requests 2Gi memory (with 6Gi or 12Gi limits) to allow scheduling on nodes with kubelet reservations.

## Security Considerations

### Running as Root (Current Configuration)

**Current Status:** BOINC pods currently run as `root` (UID 0) for compatibility.

**Security Recommendation:** Consider running BOINC as a non-root user for better security isolation.

**Why This Matters:**
- BOINC downloads and executes arbitrary scientific computing workloads from the internet
- Running as root gives these workloads full container privileges
- While containers provide some isolation, non-root is defense-in-depth

**Migration Path (To Be Tested):**
1. LXCFS files are world-readable (`/var/lib/lxcfs/proc/*`), so non-root access should work
2. Test with: `securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 }`
3. Verify BOINC tasks execute successfully and can read container memory limits
4. Check for any permission issues with `/var/lib/boinc` directory

**Trade-offs:**
- **Pro:** Better security isolation from potentially malicious BOINC tasks
- **Con:** May require additional testing and troubleshooting if tasks need specific capabilities
- **Con:** Some BOINC projects might have compatibility issues with non-root execution

**Status:** Not implemented yet - requires testing to ensure BOINC tasks work correctly as non-root.
