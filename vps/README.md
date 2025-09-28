# VPS Proxy Setup

This directory contains configuration and scripts for setting up a VPS as a reverse proxy to provide external access to your homelab services.

## Overview

The VPS acts as a public-facing gateway that forwards traffic to your homelab over a secure Tailscale tunnel. This allows you to host services at home while providing reliable external access without exposing your home network directly to the internet.

### Architecture

```
Internet Users
    ↓ (HTTPS)
VPS (Public IP)
    ↓ (Nginx Stream Proxy)
Tailscale Tunnel (WireGuard)
    ↓ (HTTP/HTTPS)
Homelab K3s Cluster
    ↓ (Traefik Ingress)
Applications
```

### Benefits

- **Security**: Home network remains private
- **Reliability**: VPS provides stable public IP
- **Flexibility**: Easy to change VPS providers
- **Cost Effective**: Small VPS sufficient for proxy duties

## Prerequisites

### VPS Requirements

**Minimum Specifications**
- **CPU**: 1 vCPU (2 vCPU recommended)
- **RAM**: 512MB (1GB recommended)
- **Storage**: 10GB (primarily for OS)
- **Network**: 1TB+ monthly transfer
- **OS**: Ubuntu 20.04/22.04 LTS or Debian 11/12

**Recommended Providers**
- DigitalOcean (Droplet)
- Linode (Nanode)
- Vultr (Regular Performance)
- Hetzner (Cloud Server)

### Network Requirements

- **Public IPv4 Address**: Required for external access
- **IPv6 Support**: Optional but recommended
- **Bandwidth**: Sufficient for your traffic needs
- **Ports**: 22 (SSH), 80 (HTTP), 443 (HTTPS)

### External Services

- **Domain Name**: With DNS management access
- **Tailscale Account**: For VPN connectivity
- **SSH Key Pair**: For secure VPS access

## Quick Setup

### 1. VPS Preparation

**Create VPS**
```bash
# Use your preferred VPS provider
# Choose Ubuntu 22.04 LTS or Debian 12
# Add your SSH public key during creation
```

**Initial Access**
```bash
# SSH to your VPS
ssh root@your-vps-ip

# Update system
apt update && apt upgrade -y

# Create non-root user (recommended)
adduser homelab
usermod -aG sudo homelab
mkdir -p /home/homelab/.ssh
cp /root/.ssh/authorized_keys /home/homelab/.ssh/
chown -R homelab:homelab /home/homelab/.ssh
chmod 700 /home/homelab/.ssh
chmod 600 /home/homelab/.ssh/authorized_keys
```

### 2. Configuration

**Clone Repository**
```bash
# As homelab user
ssh homelab@your-vps-ip
git clone <your-repo-url> homelab
cd homelab/vps
```

**Configure Environment**
```bash
# Copy configuration template
cp config/vps.env config/vps.env.local

# Edit configuration
nano config/vps.env.local
```

**Required Configuration Values**
```bash
# Your homelab's Tailscale hostname
HOME_PC_NAME="your-homelab-hostname"

# Your homelab's Tailscale IP (check with: tailscale status)
HOME_PC_IP="100.xxx.xxx.xxx"

# Your domain name
DOMAIN="your-domain.com"

# Tailscale auth key for VPS
TAILSCALE_AUTHKEY="tskey-auth-xxxxxxxxxxxxxxxx"

# SSH public key for VPS access (optional, if not set during VPS creation)
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2E..."
```

### 3. Run Setup Script

```bash
# Run the automated setup
sudo bash scripts/setup.sh
```

The setup script will:
1. Install required packages (nginx, curl, etc.)
2. Configure UFW firewall
3. Install and configure Tailscale
4. Configure Nginx for stream proxying
5. Set up SSL certificate handling
6. Configure service monitoring

### 4. DNS Configuration

**Configure DNS Records**
```bash
# Add A records pointing to your VPS public IP
your-domain.com         A    YOUR_VPS_PUBLIC_IP
*.your-domain.com       A    YOUR_VPS_PUBLIC_IP

# Optional: Add AAAA records for IPv6
your-domain.com         AAAA YOUR_VPS_IPv6
*.your-domain.com       AAAA YOUR_VPS_IPv6
```

**Verify DNS Propagation**
```bash
# Check DNS resolution
nslookup your-domain.com
nslookup jellyfin.your-domain.com

# Test from different locations
dig @8.8.8.8 your-domain.com
dig @1.1.1.1 your-domain.com
```

## Configuration Reference

### VPS Environment (`config/vps.env.local`)

**Required Settings**
```bash
# Homelab identification
HOME_PC_NAME="homelab-server"       # Tailscale hostname of homelab
HOME_PC_IP="100.121.249.71"         # Tailscale IP of homelab

# Domain configuration
DOMAIN="example.com"                 # Your primary domain

# Tailscale configuration
TAILSCALE_AUTHKEY="tskey-auth-xxx"   # Auth key from Tailscale admin

# SSH configuration (optional)
SSH_PUBLIC_KEY="ssh-rsa AAAAB3..."   # Your SSH public key
```

**Optional Settings**
```bash
# Nginx configuration
NGINX_WORKER_PROCESSES="auto"       # Nginx worker processes
NGINX_WORKER_CONNECTIONS="1024"     # Max connections per worker

# Firewall configuration
ENABLE_UFW="true"                   # Enable UFW firewall
ALLOW_SSH_FROM_ANYWHERE="true"      # Allow SSH from any IP

# Monitoring
ENABLE_MONITORING="true"            # Enable basic monitoring
```

### Nginx Configuration

The setup automatically configures Nginx for stream proxying:

**Main Configuration** (`/etc/nginx/nginx.conf`)
```nginx
# Added to main nginx.conf
include /etc/nginx/conf.d/*.conf;
include /etc/nginx/stream.d/*.conf;

# Stream block for TCP/UDP proxying
stream {
    include /etc/nginx/stream.d/*.conf;
}
```

**Stream Proxy Configuration** (`/etc/nginx/stream.d/homelab.conf`)
```nginx
# HTTP traffic (port 80)
server {
    listen 80;
    proxy_pass $HOME_PC_IP:80;
    proxy_protocol on;
    proxy_timeout 1s;
    proxy_responses 1;
}

# HTTPS traffic (port 443)
server {
    listen 443;
    proxy_pass $HOME_PC_IP:443;
    proxy_protocol on;
    proxy_timeout 1s;
    proxy_responses 1;
}
```

## Management Commands

### Service Management

**Check Service Status**
```bash
# Check all VPS services
sudo systemctl status nginx tailscaled

# Check individual services
sudo systemctl status nginx
sudo systemctl status tailscaled
```

**Restart Services**
```bash
# Restart Nginx
sudo systemctl restart nginx

# Restart Tailscale
sudo systemctl restart tailscaled

# Reload Nginx configuration
sudo nginx -s reload
```

### Monitoring

**Check Tailscale Connectivity**
```bash
# Check Tailscale status
sudo tailscale status

# Test connectivity to homelab
sudo tailscale ping your-homelab-hostname
ping 100.xxx.xxx.xxx  # homelab Tailscale IP
```

**Monitor Traffic**
```bash
# Check Nginx access logs
sudo tail -f /var/log/nginx/access.log

# Check stream proxy logs
sudo tail -f /var/log/nginx/stream_access.log

# Check error logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/stream_error.log
```

**System Monitoring**
```bash
# Check system resources
htop
df -h
free -h

# Check network connections
sudo netstat -tulnp | grep nginx
sudo ss -tulnp | grep nginx
```

### Configuration Updates

**Update Homelab IP**
```bash
# Edit configuration
nano config/vps.env.local
# Update HOME_PC_IP

# Regenerate Nginx config
sudo bash scripts/setup.sh

# Or manually update and reload
sudo nano /etc/nginx/stream.d/homelab.conf
sudo nginx -t
sudo nginx -s reload
```

**Update Domain Configuration**
```bash
# Edit configuration
nano config/vps.env.local
# Update DOMAIN

# Regenerate configuration
sudo bash scripts/setup.sh
```

## Troubleshooting

### Common Issues

**Tailscale Connection Problems**
```bash
# Check Tailscale status
sudo tailscale status

# Re-authenticate Tailscale
sudo tailscale logout
sudo tailscale up --authkey=tskey-auth-xxxxxxxx

# Check firewall
sudo ufw status
```

**Nginx Configuration Errors**
```bash
# Test Nginx configuration
sudo nginx -t

# Check Nginx error logs
sudo tail -f /var/log/nginx/error.log

# Validate stream configuration
sudo nginx -T | grep -A 10 -B 10 stream
```

**Connectivity Issues**
```bash
# Test from VPS to homelab
curl -I http://100.xxx.xxx.xxx
telnet 100.xxx.xxx.xxx 80

# Test external connectivity
curl -I http://your-domain.com
curl -I https://your-domain.com
```

**DNS Resolution Problems**
```bash
# Check DNS from VPS
nslookup your-domain.com
dig your-domain.com

# Check DNS propagation
dig @8.8.8.8 your-domain.com
dig @1.1.1.1 your-domain.com
```

### Recovery Procedures

**Reset Tailscale**
```bash
# Complete Tailscale reset
sudo tailscale logout
sudo systemctl stop tailscaled
sudo rm -rf /var/lib/tailscale/
sudo systemctl start tailscaled
sudo tailscale up --authkey=tskey-auth-xxxxxxxx
```

**Reset Nginx Configuration**
```bash
# Backup current config
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Restore from script
sudo bash scripts/setup.sh

# Or manually restore
sudo systemctl stop nginx
sudo rm -rf /etc/nginx/stream.d/
sudo bash scripts/setup.sh
sudo systemctl start nginx
```

**Complete VPS Reset**
```bash
# Remove all configurations
sudo systemctl stop nginx tailscaled
sudo apt remove --purge nginx tailscale
sudo rm -rf /etc/nginx /var/lib/tailscale

# Re-run setup
sudo bash scripts/setup.sh
```

## Security Considerations

### Firewall Configuration

**UFW Rules Applied by Setup**
```bash
# Default policies
ufw default deny incoming
ufw default allow outgoing

# SSH access
ufw allow 22/tcp

# HTTP/HTTPS access
ufw allow 80/tcp
ufw allow 443/tcp

# Enable firewall
ufw enable
```

**Additional Security Measures**
```bash
# Change SSH port (optional)
sudo nano /etc/ssh/sshd_config
# Change: Port 2222
sudo systemctl restart ssh
sudo ufw allow 2222/tcp
sudo ufw delete allow 22/tcp

# Disable password authentication
sudo nano /etc/ssh/sshd_config
# Ensure: PasswordAuthentication no
sudo systemctl restart ssh

# Enable fail2ban
sudo apt install fail2ban
sudo systemctl enable fail2ban
```

### Monitoring and Alerting

**Log Monitoring**
```bash
# Install logwatch for daily reports
sudo apt install logwatch
sudo nano /etc/cron.daily/00logwatch
# Add email configuration
```

**Basic Monitoring Script**
```bash
#!/bin/bash
# /home/homelab/monitor-vps.sh

# Check services
if ! systemctl is-active --quiet nginx; then
    echo "Nginx is down" | mail -s "VPS Alert" admin@yourdomain.com
fi

if ! systemctl is-active --quiet tailscaled; then
    echo "Tailscale is down" | mail -s "VPS Alert" admin@yourdomain.com
fi

# Check connectivity to homelab
if ! ping -c 1 100.xxx.xxx.xxx >/dev/null 2>&1; then
    echo "Cannot reach homelab" | mail -s "VPS Alert" admin@yourdomain.com
fi
```

## Advanced Configuration

### Load Balancing

For multiple homelab instances:

```nginx
# /etc/nginx/stream.d/homelab-lb.conf
upstream homelab_http {
    server 100.xxx.xxx.1:80;
    server 100.xxx.xxx.2:80;
}

upstream homelab_https {
    server 100.xxx.xxx.1:443;
    server 100.xxx.xxx.2:443;
}

server {
    listen 80;
    proxy_pass homelab_http;
    proxy_protocol on;
}

server {
    listen 443;
    proxy_pass homelab_https;
    proxy_protocol on;
}
```

### SSL Termination on VPS

If you prefer SSL termination on VPS:

```nginx
# /etc/nginx/sites-available/homelab-ssl
server {
    listen 443 ssl http2;
    server_name *.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://100.xxx.xxx.xxx;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### IPv6 Support

```nginx
# Add IPv6 listeners
server {
    listen [::]:80;
    listen [::]:443;
    # ... rest of configuration
}
```

## Cost Optimization

### Monitoring Usage

```bash
# Monitor bandwidth usage
vnstat -d
vnstat -m

# Check resource usage
htop
iotop
```

### Optimization Tips

- **Choose appropriate VPS size**: Start small, scale as needed
- **Monitor transfer limits**: Avoid overage charges
- **Use compression**: Enable gzip in Nginx
- **Consider CDN**: For static content if needed
- **Regional selection**: Choose VPS region close to users

This VPS proxy setup provides a robust, secure gateway for external access to your homelab services while maintaining simplicity and cost-effectiveness.