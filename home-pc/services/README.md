# Services

This directory contains Docker Compose configurations for various services that run on the home PC.

Traefik is configured for **automatic service discovery** - just add the right labels and your service will "just work"!

## How Traefik Auto-Discovery Works

1. **Shared Network**: All services connect to the `traefik` external network
2. **Docker Labels**: Traefik reads container labels to configure routing automatically
3. **Live Updates**: When you start/stop containers, Traefik updates routes instantly

## Adding a New Service (Template)

1. Create a directory: `services/my-service/`
2. Add `docker-compose.yml` with these essential labels:

```yaml
version: '3.8'
services:
  my-service:
    image: your-image:latest
    container_name: my-service
    restart: unless-stopped
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-service.rule=Host(`my-service.homelab.local`)"
      - "traefik.http.routers.my-service.entrypoints=websecure"
      - "traefik.http.routers.my-service.tls.certresolver=letsencrypt"
      - "traefik.http.services.my-service.loadbalancer.server.port=8080"  # Your app's port

networks:
  traefik:
    external: true
```

3. Deploy: `cd services/my-service && docker-compose up -d`
4. Access: `https://my-service.homelab.local` (auto HTTPS!)

## Essential Traefik Labels

- **`traefik.enable=true`**: Enable Traefik for this service
- **`traefik.http.routers.NAME.rule`**: Routing rule (usually Host)
- **`traefik.http.routers.NAME.entrypoints`**: Use `websecure` for HTTPS
- **`traefik.http.routers.NAME.tls.certresolver`**: Use `letsencrypt` for auto SSL
- **`traefik.http.services.NAME.loadbalancer.server.port`**: Your container's port

## Examples

- **whoami/**: Simple diagnostic service showing request info
- **example-app/**: Basic nginx service

That's it! No nginx configs, no manual SSL setup - Traefik handles everything automatically.