# Homelab Infrastructure

A secure, automated homelab setup using Tailscale for private networking, with a VPS acting as a reverse proxy to services running on your home PC.

## Architecture

```
Internet → VPS (Nginx) → Tailscale Tunnel → Home PC (Traefik) → Docker Services
```

- **VPS**: Public-facing reverse proxy using Nginx stream module
- **Home PC**: Private services behind Traefik with automatic HTTPS
- **Tailscale**: Secure WireGuard-based mesh network connecting VPS and home PC
- **Security**: Firewall restrictions, SSH key auth, proxy protocol support

## Quick Start

### Prerequisites

- A VPS with root access (Ubuntu/Debian recommended)
- A home PC/server (Ubuntu/Debian recommended) 
- A Tailscale account ([tailscale.com](https://tailscale.com))
- A domain name with DNS pointing to your VPS IP

### 1. Setup VPS

```bash
# Clone repository on VPS
git clone <your-repo-url>
cd homelab/vps

# Configure environment
cp config/vps.env config/vps.env.local
vim config/vps.env.local  # Set HOME_PC_NAME, TAILSCALE_AUTHKEY, SSH_PUBLIC_KEY

# Run setup script
sudo bash scripts/setup.sh
```

### 2. Setup Home PC

```bash
# Clone repository on home PC
git clone <your-repo-url>
cd homelab/home-pc

# Configure environment
cp config/home-pc.env config/home-pc.env.local
vim config/home-pc.env.local  # Set VPS_HOSTNAME, TAILSCALE_AUTHKEY

# Run setup script
sudo bash scripts/setup.sh
```

### 3. Deploy Services

Services are automatically deployed during setup. Add new services to `home-pc/services/` and they'll be discovered by Traefik automatically.

## Configuration

### VPS Environment (`vps/config/vps.env.local`)

```bash
# Home PC configuration
HOME_PC_NAME=your-homepc-hostname

# Tailscale configuration
TAILSCALE_AUTHKEY=tskey-auth-xxxxx

# SSH public key for secure access
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2E..."
```

### Home PC Environment (`home-pc/config/home-pc.env.local`)

```bash
# VPS configuration  
VPS_HOSTNAME=your-vps-hostname
VPS_IP=100.121.249.71  # Tailscale IP

# Tailscale configuration
TAILSCALE_AUTHKEY=tskey-auth-xxxxx

# Docker configuration
DOCKER_USER=your-username

# Traefik configuration
TRAEFIK_DIR=~/traefik
SERVICES_DIR=./services
```

## Adding Services

### Method 1: Automatic (Recommended)

1. Create service directory: `mkdir home-pc/services/my-app`
2. Add docker-compose.yml with Traefik labels:

```yaml
services:
  my-app:
    image: your-app:latest
    container_name: my-app
    restart: unless-stopped
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-app.rule=Host(`my-app.yourdomain.com`)"
      - "traefik.http.routers.my-app.entrypoints=websecure"
      - "traefik.http.routers.my-app.tls.certresolver=letsencrypt"
      - "traefik.http.services.my-app.loadbalancer.server.port=8080"

networks:
  traefik:
    external: true
```

3. Deploy: `cd home-pc/services/my-app && docker-compose up -d`
4. Access: `https://my-app.yourdomain.com` (automatic HTTPS!)

### Method 2: Manual Deployment

Services placed in `home-pc/services/` are automatically deployed by the setup script. Restart services with:

```bash
cd home-pc/services/service-name
docker-compose pull && docker-compose up -d
```

## Security Features

### Network Security
- **UFW Firewall**: VPS allows only necessary ports (22, 80, 443, 51422)
- **Tailscale Mesh**: All traffic between VPS and home PC encrypted via WireGuard
- **Home PC Firewall**: Only accepts connections from VPS Tailscale IP

### Access Control  
- **SSH Key Authentication**: Password login disabled on VPS
- **Proxy Protocol**: Real client IPs preserved through proxy chain
- **Automatic HTTPS**: Let's Encrypt certificates for all services

### Service Isolation
- **Docker Networks**: Services isolated in separate network namespaces
- **Traefik Network**: Shared network for service discovery only
- **Container Restart Policies**: Services auto-recover from failures

## Monitoring & Maintenance

### Check Service Status
```bash
# On home PC
docker ps
docker-compose -f ~/traefik/docker-compose.yml logs

# Check Tailscale connectivity
tailscale status
```

### Update Services
```bash
# Update all services
cd home-pc/services
for dir in */; do
  (cd "$dir" && docker-compose pull && docker-compose up -d)
done
```

### View Logs
```bash
# Traefik logs
docker logs traefik

# Service logs
docker logs <container-name>

# Nginx logs (on VPS)
tail -f /var/log/nginx/stream_access.log
tail -f /var/log/nginx/stream_error.log
```

## Included Services

- **Traefik Dashboard**: `https://traefik.local` (home PC only)
- **Whoami**: `https://whoami.cliff.li` - Request diagnostic tool
- **Example App**: `https://example.homelab.local` - Sample Nginx service
- **Nextcloud**: `https://drive.cliff.li` - Complete cloud storage and collaboration platform

## Ports & Protocols

### VPS
- `22/tcp`: SSH access
- `80/tcp`: HTTP (redirects to HTTPS)
- `443/tcp`: HTTPS traffic
- `443/udp`: HTTP/3 support
- `51422/tcp`: SSH passthrough to home PC

### Home PC (Tailscale only)
- `80/tcp`: Traefik HTTP entrypoint
- `443/tcp`: Traefik HTTPS entrypoint  
- `22/tcp`: SSH access via VPS port 51422

## Troubleshooting

### Tailscale Connection Issues
```bash
# Check Tailscale status
tailscale status

# Restart Tailscale
sudo systemctl restart tailscaled
tailscale up --authkey=<your-key>
```

### Service Not Accessible
1. Check if container is running: `docker ps`
2. Check Traefik routes: `docker logs traefik`
3. Verify DNS points to VPS IP
4. Check firewall rules: `sudo ufw status`

### SSL Certificate Issues
```bash
# Check certificate status
docker exec traefik cat /acme.json

# Force certificate renewal
docker-compose -f ~/traefik/docker-compose.yml restart
```

### Network Connectivity
```bash
# Test VPS to home PC connection
# On VPS:
curl -I http://<HOME_PC_TAILSCALE_IP>

# Test home PC to internet
# On home PC:
curl -I https://google.com
```

## Advanced Configuration

### Custom Nginx Configuration
Modify `vps/nginx/nginx.conf.template` to customize the VPS proxy behavior.

### Traefik Configuration  
Edit `home-pc/traefik/traefik.yml` for advanced Traefik settings.

### Environment Overrides
Use `.env.local` files to override default configurations without committing sensitive data.
