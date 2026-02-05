# Troubleshooting Guide

## Quick Diagnostics

```bash
./scripts/homelab.sh status       # Overall status
kubectl get nodes                  # Cluster nodes
kubectl get pods -A               # All pods
sudo tailscale status            # VPN connectivity
df -h                            # Disk usage
```

## Common Issues

### Pods Not Starting

```bash
# Check status and events
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl get events --sort-by='.lastTimestamp' -A

# Common causes:
# - ImagePullBackOff: Check image name/tag
# - Pending: Check node resources (kubectl top nodes)
# - CrashLoopBackOff: Check logs (kubectl logs -n <ns> <pod>)
```

### Storage Issues

```bash
# Check PVCs
kubectl get pvc -A

# Check disk space
df -h /media/data /opt/k3s-storage

# Fix permissions
sudo chown -R $USER:$USER /opt/k3s-storage/<service>/
```

### Network/Connectivity

```bash
# Tailscale
sudo tailscale status
sudo tailscale ping <hostname>

# DNS from inside cluster
kubectl exec -it -n utilities deployment/whoami -- nslookup google.com

# Cross-node communication (if failing, check Flannel VXLAN)
sudo ufw status | grep 8472
# If missing: sudo ufw allow from 192.168.0.0/16 to any port 8472 proto udp
```

### Certificate Issues

```bash
# Check certificates
kubectl get certificates -A
kubectl describe certificate <cert-name> -n <namespace>

# Check challenges
kubectl get challenges -A

# Force renewal (delete certificate request)
kubectl delete certificaterequest -n <namespace> <cert-request-name>

# cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

### Service Not Accessible

```bash
# Check ingress
kubectl get ingress -A
kubectl describe ingress <name> -n <namespace>

# Test internally via port-forward
kubectl port-forward -n <namespace> deployment/<service> 8080:<port>
curl http://localhost:8080

# Check Traefik
kubectl logs -n kube-system deployment/traefik --tail=50
```

## Emergency Recovery

```bash
# Restart K3s
sudo systemctl restart k3s

# Redeploy all applications
./scripts/homelab.sh deploy
```

## Collecting Debug Info

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events --sort-by='.lastTimestamp' -A | tail -30
kubectl logs -n kube-system deployment/traefik --tail=20
sudo tailscale status
df -h
```
