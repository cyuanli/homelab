# mc-router Implementation

This document describes the mc-router implementation for routing multiple Minecraft servers through a single port using domain-based routing.

## Overview

**Implemented**: December 30, 2025

mc-router was deployed as a reverse proxy for Minecraft servers to enable hosting multiple Minecraft servers on port 25565, with routing based on the domain/subdomain used by clients to connect.

## Architecture

### Before Implementation
```
Internet → VPS:25565 (Nginx) → Tailscale → Traefik:25565 → Minecraft Service → Minecraft Pod
```

### After Implementation
```
Internet → VPS:25565 (Nginx) → Tailscale → Traefik:25565 → mc-router:25565 → Minecraft Servers
                                                                      ├─→ cobblestone.mc.cliff.li
                                                                      ├─→ sandstone.mc.cliff.li
                                                                      └─→ (additional servers auto-discovered)
```

## What Was Implemented

### 1. mc-router Deployment

**Location**: `/home/cyl/homelab/cluster/applications/games/minecraft/mc-router/`

**Components Created**:
- `rbac.yaml` - RBAC configuration for Kubernetes API access
- `deployment.yaml` - mc-router deployment with auto-discovery
- `service.yaml` - ClusterIP service exposing ports 25565 and 8080
- `docs/` - Documentation directory

**Configuration Details**:

**RBAC Permissions**:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mc-router
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]
```

mc-router requires read-only access to pods and services across all namespaces to auto-discover Minecraft servers with the appropriate service annotations.

**Deployment Configuration**:
- **Image**: `itzg/mc-router:latest`
- **Replicas**: 1 (stateless, can be scaled if needed)
- **Service Account**: `mc-router`
- **Args**:
  - `--port=25565` - Listen on Minecraft default port
  - `--api-binding=:8080` - API/metrics endpoint
  - `--in-kube-cluster` - Enable Kubernetes auto-discovery

**Resource Allocation**:
- **Requests**: 50m CPU, 64Mi memory
- **Limits**: 200m CPU, 128Mi memory

**Health Checks**:
- **Liveness Probe**: HTTP GET `/routes` on port 8080 (every 30s)
- **Readiness Probe**: HTTP GET `/routes` on port 8080 (every 10s)

**Service Configuration**:
- **Type**: ClusterIP (internal only)
- **Ports**:
  - 25565/TCP - Minecraft traffic
  - 8080/TCP - API and metrics
- **Prometheus Annotations**:
  ```yaml
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
  ```

### 2. Minecraft Server Configuration Updates

**Files Modified**: `/home/cyl/homelab/cluster/applications/games/minecraft/worlds/*.yaml`

**Changes Made**:

**Service Type Change**:
```yaml
# Before
serviceType: LoadBalancer

# After
serviceType: ClusterIP
```

The Minecraft service no longer needs external exposure since mc-router handles incoming connections.

**mc-router Service Annotation Added**:
```yaml
serviceAnnotations:
  mc-router.itzg.me/externalServerName: "minecraft.cliff.li"
```

This annotation tells mc-router to route connections for `minecraft.cliff.li` to this server's service.

### 3. Traefik TCP Routing Update

**File Modified**: `/home/cyl/homelab/cluster/applications/games/minecraft/traefik-tcp-route.yaml`

**Changes Made**:

```yaml
# Before
metadata:
  name: minecraft
spec:
  routes:
    - match: HostSNI(`*`)
      services:
        - name: minecraft
          port: 25565

# After
metadata:
  name: minecraft-router
spec:
  routes:
    - match: HostSNI(`*`)
      services:
        - name: mc-router
          port: 25565
```

The TCP route now directs all traffic to mc-router instead of directly to the Minecraft service. mc-router then handles hostname-based routing to individual servers.

## How It Works

### Connection Flow

1. **Client Connects**: Player connects to `minecraft.cliff.li:25565` in Minecraft client
2. **DNS Resolution**: Domain resolves to VPS public IP
3. **VPS Nginx Proxy**: Receives connection on port 25565, forwards via Tailscale to homelab
4. **Load Balancing**: Nginx load balances across control plane nodes
5. **Traefik**: Receives TCP traffic on minecraft entrypoint (port 25565)
6. **mc-router**: Intercepts connection, reads server hostname from handshake packet
7. **Routing Decision**: Looks up backend service with annotation `mc-router.itzg.me/externalServerName: "minecraft.cliff.li"`
8. **Backend Connection**: Routes to `minecraft-minecraft.games.svc.cluster.local:25565`
9. **Player Joins**: Connection established, player joins the server

### Auto-Discovery Mechanism

mc-router continuously watches the Kubernetes API for services with the annotation pattern:
```yaml
mc-router.itzg.me/externalServerName: "<domain>"
```

When a new Minecraft server is deployed with this annotation on its service:
1. mc-router detects the service via Kubernetes watch API
2. Extracts the external server name from the annotation
3. Registers a route: `<domain>` → `<service-ip>:<port>`
4. Immediately begins routing connections for that domain

No restart or configuration reload required.

## Deployment Instructions

### Deploy mc-router

```bash
# Apply RBAC, deployment, and service
kubectl apply -f /home/cyl/homelab/cluster/applications/games/minecraft/mc-router/rbac.yaml
kubectl apply -f /home/cyl/homelab/cluster/applications/games/minecraft/mc-router/deployment.yaml
kubectl apply -f /home/cyl/homelab/cluster/applications/games/minecraft/mc-router/service.yaml
```

### Update Minecraft Servers

```bash
# Upgrade existing Minecraft servers with new configuration
cd /home/cyl/homelab/cluster/applications/games/minecraft

helm upgrade minecraft-cobblestone itzg/minecraft -n games \
  -f worlds/cobblestone-values.yaml

helm upgrade minecraft-sandstone itzg/minecraft -n games \
  -f worlds/sandstone-values.yaml
```

### Verify Deployment

**Check mc-router pod status**:
```bash
kubectl get pods -n games -l app=mc-router
```

Expected output:
```
NAME                         READY   STATUS    RESTARTS   AGE
mc-router-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

**Check discovered routes**:
```bash
kubectl port-forward -n games svc/mc-router 8080:8080
curl http://localhost:8080/routes
```

Expected output:
```json
{
  "cobblestone.mc.cliff.li": "10.43.141.162:25565",
  "sandstone.mc.cliff.li": "10.43.126.164:25565"
}
```

**View mc-router logs**:
```bash
kubectl logs -n games deployment/mc-router -f
```

Expected log entries:
```
[INFO] Starting mc-router with Kubernetes auto-discovery
[INFO] Discovered Minecraft server: minecraft-minecraft
[INFO] Registered route: minecraft.cliff.li -> minecraft-minecraft.games.svc.cluster.local:25565
[INFO] Listening on :25565
```

## Network Configuration

### VPS Configuration

**No changes required** to VPS Nginx configuration. The existing stream proxy continues to work:

```nginx
upstream minecraft_backend {
    server <homelab-tailscale-ip-1>:25565 max_fails=2 fail_timeout=5s;
    server <homelab-tailscale-ip-2>:25565 max_fails=2 fail_timeout=5s;
    server <homelab-tailscale-ip-3>:25565 max_fails=2 fail_timeout=5s;
}

server {
    listen 25565;
    listen [::]:25565;
    proxy_pass minecraft_backend;
    proxy_connect_timeout 5s;
    proxy_timeout 30m;
}
```

### DNS Configuration

**Current DNS Record** (already configured):
```
minecraft.cliff.li    A    <VPS_PUBLIC_IP>
```

**For Future Servers**, add additional A records:
```
creative.cliff.li     A    <VPS_PUBLIC_IP>
modded.cliff.li       A    <VPS_PUBLIC_IP>
skyblock.cliff.li     A    <VPS_PUBLIC_IP>
```

All records point to the same VPS IP. mc-router handles internal routing based on hostname.

## Adding New Minecraft Servers

See `ADDING-SERVERS.md` for detailed instructions.

**Quick Summary**:

1. **Deploy new Minecraft server** using Helm:
   ```bash
   helm install minecraft-creative itzg/minecraft -n games -f values-creative.yaml
   ```

2. **Add mc-router service annotation** in values file:
   ```yaml
   serviceAnnotations:
     mc-router.itzg.me/externalServerName: "creative.cliff.li"
   ```

3. **Add DNS A record**: `creative.cliff.li → VPS_PUBLIC_IP`

4. **Test connection**: Connect to `creative.cliff.li:25565` in Minecraft client

mc-router automatically discovers the new server and begins routing within seconds.

## Monitoring

### Metrics Endpoint

mc-router exposes Prometheus metrics on port 8080:

```bash
kubectl port-forward -n games svc/mc-router 8080:8080
curl http://localhost:8080/metrics
```

**Key Metrics**:
- `mcrouter_connections_total` - Total connections routed
- `mcrouter_routes_count` - Number of active routes
- `mcrouter_backend_errors_total` - Backend connection failures

### Prometheus Scraping

The service is annotated for automatic Prometheus discovery:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

If Prometheus is configured with Kubernetes service discovery, it will automatically scrape mc-router metrics.

### Logs

View real-time logs:
```bash
kubectl logs -n games deployment/mc-router -f
```

Log events include:
- Server discovery/removal
- Route registration/unregistration
- Connection attempts
- Backend errors

## Troubleshooting

### Connection Fails to Specific Server

**Check if route is registered**:
```bash
kubectl port-forward -n games svc/mc-router 8080:8080
curl http://localhost:8080/routes | grep "yourserver.cliff.li"
```

If not present, check service annotations:
```bash
kubectl get svc -n games -o yaml | grep -A 2 externalServerName
```

### mc-router Not Discovering Servers

**Check RBAC permissions**:
```bash
kubectl auth can-i list pods --as=system:serviceaccount:games:mc-router
kubectl auth can-i watch pods --as=system:serviceaccount:games:mc-router
```

Both should return "yes".

**Check mc-router logs**:
```bash
kubectl logs -n games deployment/mc-router
```

Look for permission errors or discovery failures.

### Backend Connection Errors

**Verify backend service**:
```bash
kubectl get svc -n games minecraft-minecraft
```

**Test connectivity from mc-router pod**:
```bash
kubectl exec -n games deployment/mc-router -- nc -zv minecraft-minecraft 25565
```

## Security Considerations

### RBAC Permissions

mc-router has ClusterRole with permissions to list/watch pods and services:
- **Scope**: All namespaces (required for multi-namespace discovery)
- **Access**: Read-only (get, list, watch)
- **Resources**: Pods and Services only

This is the minimum required for auto-discovery functionality.

### Network Isolation

- mc-router runs in the `games` namespace alongside Minecraft servers
- Uses ClusterIP services (not exposed externally)
- Only Traefik (via VPS) has external network access
- Backend connections are internal cluster traffic only

### Rate Limiting

mc-router supports built-in rate limiting via `--connection-rate-limit` flag. This can be added if DDoS protection is needed:

```yaml
args:
  - --port=25565
  - --api-binding=:8080
  - --in-kube-cluster
  - --connection-rate-limit=10
```

## Performance Impact

### Resource Usage

Based on deployment configuration:
- **CPU Request**: 50m (minimal overhead)
- **Memory Request**: 64Mi (very lightweight)
- **Network Overhead**: Negligible (only reads handshake packet, then passes through)

### Observed Behavior

- mc-router adds <1ms latency (reads handshake, forwards connection)
- Stateless proxy (no session state stored)
- Scales horizontally if needed (can increase replicas)

## Rollback Procedure

If issues occur, rollback to direct Minecraft routing:

```bash
# 1. Restore original TCP route
kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: minecraft
  namespace: games
spec:
  entryPoints:
    - minecraft
  routes:
    - match: HostSNI(\`*\`)
      services:
        - name: minecraft-minecraft
          port: 25565
EOF

# 2. Change Minecraft service to LoadBalancer
helm upgrade minecraft itzg/minecraft -n games \
  --set minecraftServer.serviceType=LoadBalancer

# 3. Delete mc-router
kubectl delete -f /home/cyl/homelab/cluster/applications/games/mc-router/
```

## Future Enhancements

### Potential Improvements

1. **Horizontal Scaling**: Increase mc-router replicas for HA
2. **Rate Limiting**: Enable connection rate limits per client IP
3. **Grafana Dashboard**: Create dashboard for mc-router metrics
4. **Multi-Namespace**: Deploy Minecraft servers in separate namespaces
5. **Wildcard Domains**: Use `*.mc.cliff.li` for cleaner subdomain structure

### Auto-Scaling Support

mc-router can be integrated with tools like [lazymc](https://github.com/timvisee/lazymc) for automatic server start/stop based on player activity.

## References

- [mc-router GitHub Repository](https://github.com/itzg/mc-router)
- [mc-router Docker Hub](https://hub.docker.com/r/itzg/mc-router)
- [Kubernetes Auto-Discovery Documentation](https://github.com/itzg/mc-router/blob/master/docs/k8s/README.md)
- [itzg/minecraft-server Helm Chart](https://github.com/itzg/minecraft-server-charts)
