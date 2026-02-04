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

## Backups

```bash
# Check borgmatic status
journalctl -u borgmatic.service -n 50

# Manual backup
sudo systemctl start borgmatic.service

# View backup metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom
```

## Scheduled Tasks

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `snapraid-runner` | Daily 2 AM | SnapRAID sync/scrub |
| `disk-monitor` | Every 5 min | Disk health checks |
| `borgmatic` | Daily 3 AM | Backups |

```bash
systemctl list-timers                    # All timers
journalctl -u <service>.service -n 50   # Timer logs
```

## Monitoring

```bash
# Prometheus metrics
cat /var/lib/node_exporter/textfile_collector/*.prom

# Grafana: https://grafana.cliff.li
# Prometheus: https://prometheus.cliff.li
# Alertmanager: https://alertmanager.cliff.li
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
