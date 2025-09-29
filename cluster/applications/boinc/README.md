# BOINC Scientific Computing

This deploys BOINC (Berkeley Open Infrastructure for Network Computing) clients across the K3s cluster to contribute computing power to scientific research projects.

## What's Deployed

- **3 BOINC client replicas** - One per node for distributed computing
- **Scientific Projects**: World Community Grid, Einstein@Home, Rosetta@home, SETI@home, LHC@home
- **Resource Limits**: Max 2 CPU cores and 2GB RAM per pod
- **Node Distribution**: Anti-affinity ensures pods spread across all nodes

## Management

### Deploy
```bash
kubectl apply -k cluster/applications/boinc/
```

### Monitor
```bash
# Check pod status
kubectl get pods -n boinc

# View logs
kubectl logs -n boinc -l app=boinc-client

# Check resource usage
kubectl top pods -n boinc
```

### BOINC Commands
Access BOINC client directly:
```bash
# Get shell access
kubectl exec -it -n boinc deployment/boinc-client -- bash

# Check project status
kubectl exec -n boinc deployment/boinc-client -- boinccmd --get_project_status

# Check tasks
kubectl exec -n boinc deployment/boinc-client -- boinccmd --get_tasks

# Check daily statistics
kubectl exec -n boinc deployment/boinc-client -- boinccmd --get_daily_xfer_history
```

## Configuration

- **CPU Usage**: Limited to 75% to avoid impacting other services
- **Memory**: 80% when busy, 90% when idle
- **Disk Space**: 10GB max per pod, 50% of available
- **Network**: No bandwidth limits

## Projects Contributing To

1. **World Community Grid** - Clean energy, medical research
2. **Einstein@Home** - Gravitational wave detection
3. **Rosetta@home** - Protein folding for disease research
4. **SETI@home** - Search for extraterrestrial intelligence
5. **LHC@home** - Large Hadron Collider particle physics

## Gridcoin Integration

To earn Gridcoin (GRC) cryptocurrency for your BOINC contributions:

1. Install Gridcoin wallet on any machine
2. Create a "beacon" linking your BOINC Cross-Project ID (CPID)
3. Change username on one BOINC project to match your Gridcoin address
4. Stake GRC to earn rewards proportional to your scientific contribution

Your BOINC work will automatically be credited to your Gridcoin wallet for cryptocurrency rewards!