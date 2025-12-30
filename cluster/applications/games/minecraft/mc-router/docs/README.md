# mc-router

Reverse proxy for Minecraft servers that enables routing multiple Minecraft servers through a single port (25565) based on the domain/subdomain used by clients.

## Components

- `rbac.yaml` - ServiceAccount and ClusterRole for Kubernetes API access
- `deployment.yaml` - mc-router deployment with auto-discovery
- `service.yaml` - ClusterIP service with Prometheus metrics annotations

## How It Works

mc-router uses Kubernetes auto-discovery to find Minecraft servers with the label:
```yaml
mc-router.itzg.me/externalServerName: "subdomain.cliff.li"
```

When a client connects to a specific domain, mc-router reads the hostname from the Minecraft handshake packet and routes the connection to the appropriate backend server.

## Deployment

```bash
kubectl apply -f rbac.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

## Monitoring

Check discovered routes:
```bash
kubectl port-forward -n games svc/mc-router 8080:8080
curl http://localhost:8080/routes
```

View logs:
```bash
kubectl logs -n games deployment/mc-router -f
```

## Adding New Minecraft Servers

See `ADDING-SERVERS.md` for instructions on adding new Minecraft servers to mc-router.
