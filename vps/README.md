# VPS Proxy Setup

The VPS acts as a public-facing gateway that forwards traffic to your homelab over Tailscale.

```
Internet → VPS (Nginx) → Tailscale VPN → K3s Cluster (Traefik) → Applications
```

## Quick Setup

1. **On VPS** (Ubuntu/Debian):
   ```bash
   git clone <repo-url> homelab
   cd homelab/vps
   cp config/vps.env config/vps.env.local
   ```

2. **Configure** `config/vps.env.local`:
   ```bash
   HOME_PC_NAMES="cyl-homelab cyl-optiplex9020 cyl-mitx"  # Tailscale hostnames
   TAILSCALE_AUTHKEY="tskey-auth-..."
   ```

3. **Run setup**:
   ```bash
   sudo bash scripts/setup.sh
   ```

4. **Configure DNS**: Point `*.your-domain.com` to VPS public IP

## Features

- **Load Balancing**: Round-robin across control plane nodes
- **Automatic Failover**: Health checks (`max_fails=2 fail_timeout=5s`)
- **SSL Passthrough**: Certificates handled by Traefik on homelab

## Management

```bash
# Check status
sudo systemctl status nginx tailscaled

# View logs
sudo tail -f /var/log/nginx/stream_error.log

# Test connectivity
sudo tailscale status
ping 100.x.x.x  # Homelab Tailscale IP
```

## Troubleshooting

```bash
# Tailscale issues
sudo tailscale logout
sudo tailscale up --authkey=<key>

# Nginx issues
sudo nginx -t                    # Test config
sudo systemctl restart nginx
```
