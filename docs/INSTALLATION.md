# Installation Guide

This guide provides step-by-step instructions for installing the complete homelab infrastructure from scratch.

## Prerequisites

### Hardware Requirements

**Minimum Requirements**
- **CPU**: 2 cores (4 recommended)
- **RAM**: 4GB (8GB recommended)
- **Storage**: 50GB system + storage for media/data
- **Network**: Stable internet connection

**Recommended Setup**
- **CPU**: 4+ cores for media transcoding
- **RAM**: 16GB+ for multiple services
- **Storage**: SSD for system, large drives for media storage
- **Network**: Gigabit LAN, reliable internet for VPS connectivity

### Software Prerequisites

**Base System**
- Fresh Debian 11/12 or Ubuntu 20.04/22.04 LTS
- Root or sudo access
- SSH access configured
- Basic networking configured

**External Services**
- **Tailscale Account**: Sign up at [tailscale.com](https://tailscale.com)
- **Domain Name**: For SSL certificates and external access
- **VPS (Optional)**: For external proxy if needed
- **Discord (Optional)**: For monitoring notifications

### Pre-Installation Checklist

- [ ] Fresh Linux installation completed
- [ ] SSH access working
- [ ] Internet connectivity verified
- [ ] Tailscale account created
- [ ] Domain DNS configured (if using VPS)
- [ ] Storage drives mounted (if using external storage)

## Installation Process

### Step 1: Repository Setup

**1.1 Clone the Repository**
```bash
# As regular user (not root)
cd ~
git clone <your-repo-url> homelab
cd homelab
```

**1.2 Verify Repository Structure**
```bash
# Should see: cluster/, config/, scripts/, vps/, etc.
ls -la
```

### Step 2: Configuration

**2.1 Create Main Configuration**
```bash
# Copy template and edit
cp config/homelab.env.template config/homelab.env
nano config/homelab.env
```

**2.2 Required Configuration Values**

Edit `config/homelab.env` with your specific values:

```bash
# Domain and networking
DOMAIN="your-domain.com"                    # Your domain name
ACME_EMAIL="you@your-domain.com"           # Email for Let's Encrypt

# User configuration
HOMELAB_USER="your-username"               # Your Linux username
HOMELAB_UID="1000"                         # Your user ID (run: id -u)
HOMELAB_GID="1000"                         # Your group ID (run: id -g)

# Tailscale configuration
TAILSCALE_AUTHKEY="tskey-auth-xxxxx"       # From Tailscale admin console

# Storage configuration
DATA_ROOT="/path/to/your/data"             # Where your media/data lives
K8S_STORAGE_ROOT="/opt/k3s-storage"        # K8s persistent storage

# VPS configuration (if using VPS proxy)
VPS_IP="100.x.x.x"                        # Tailscale IP of your VPS

# Monitoring (optional)
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

**2.3 Obtain Tailscale Auth Key**

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Generate a new auth key
3. Copy the key (starts with `tskey-auth-`)
4. Add to `config/homelab.env`

**2.4 Configure Storage Paths**

```bash
# Ensure your data directory exists and is accessible
sudo mkdir -p /path/to/your/data
sudo chown $USER:$USER /path/to/your/data

# For media stack, create subdirectories
mkdir -p /path/to/your/data/media/{movies,tv,music}
mkdir -p /path/to/your/data/downloads
```

### Step 3: System Installation

**3.1 Run Complete Setup**
```bash
# This will install everything: system packages, K3s, and applications
./scripts/homelab.sh setup-all
```

The setup process will:
1. Install required packages (Docker, curl, git, etc.)
2. Configure UFW firewall
3. Install and configure Tailscale
4. Install K3s with Tailscale networking
5. Deploy core infrastructure (Traefik, storage)
6. Deploy applications (media stack, Nextcloud, etc.)
7. Setup monitoring and notifications

**3.2 Monitor Installation Progress**

The script will show progress and pause for confirmations:
- Tailscale authentication (follow URL to authenticate)
- System package installations
- K3s cluster initialization
- Application deployments

**Expected Duration**: 10-20 minutes depending on internet speed

### Step 4: Post-Installation Verification

**4.1 Verify Cluster Status**
```bash
# Check cluster health
./scripts/homelab.sh status

# Should show:
# - K3s node ready
# - All pods running
# - Tailscale connected
```

**4.2 Verify Services**
```bash
# Check all pods are running
kubectl get pods -A

# Check services
kubectl get services -A

# Check ingress
kubectl get ingress -A
```

**4.3 Test Local Access**
```bash
# Test whoami service (should work immediately)
curl -k https://whoami.your-domain.com

# Check Traefik dashboard (if enabled)
curl -k https://traefik.your-domain.com
```

### Step 5: VPS Proxy Setup (Optional)

If you want external access via VPS proxy:

**5.1 VPS Configuration**
```bash
# On your VPS
git clone <your-repo-url> homelab
cd homelab/vps

# Configure VPS settings
cp config/vps.env config/vps.env.local
nano config/vps.env.local
```

**5.2 VPS Configuration Values**
```bash
# In vps/config/vps.env.local
HOME_PC_TAILSCALE_IP="100.x.x.x"          # Your homelab's Tailscale IP
DOMAIN="your-domain.com"                   # Same domain as homelab
TAILSCALE_AUTHKEY="tskey-auth-xxxxx"       # Tailscale auth key
```

**5.3 Run VPS Setup**
```bash
# On VPS
sudo bash scripts/setup.sh
```

**5.4 DNS Configuration**
```bash
# Configure DNS A records to point to VPS public IP
your-domain.com         → VPS_PUBLIC_IP
*.your-domain.com       → VPS_PUBLIC_IP
```

### Step 6: Service Configuration

**6.1 Configure Service Authentication**
```bash
# Setup HTTP Basic Auth for admin services
./scripts/homelab.sh setup-auth

# This creates credentials for Traefik dashboard, etc.
```

**6.2 Configure Media Stack**

For the media stack to work properly:

1. **Configure Prowlarr** (https://prowlarr.your-domain.com):
   - Add indexers for content discovery
   - Configure API keys

2. **Configure Sonarr** (https://sonarr.your-domain.com):
   - Add Prowlarr as indexer source
   - Configure qBittorrent as download client
   - Set up media folders

3. **Configure Radarr** (https://radarr.your-domain.com):
   - Add Prowlarr as indexer source
   - Configure qBittorrent as download client
   - Set up media folders

4. **Configure qBittorrent** (https://qbittorrent.your-domain.com):
   - Set download directory to `/downloads`
   - Configure categories for Sonarr/Radarr

5. **Configure Jellyfin** (https://jellyfin.your-domain.com):
   - Add media libraries pointing to `/media`
   - Configure users and permissions

**6.3 Configure Nextcloud**

Access Nextcloud at https://drive.your-domain.com:
1. Complete initial setup wizard
2. Create admin account
3. Configure storage and apps as needed

### Step 7: Monitoring Setup

**7.1 Test Storage Monitoring**
```bash
# Test monitoring system
./scripts/homelab.sh monitor test-alert

# Should receive Discord notification if webhook configured
```

**7.2 Configure Monitoring**
```bash
# View monitoring configuration
cat config/service-configs/monitoring.conf

# Start monitoring service
./scripts/homelab.sh monitor start
```

## Installation Troubleshooting

### Common Issues

**Tailscale Authentication Fails**
```bash
# Check Tailscale status
sudo tailscale status

# Re-authenticate if needed
sudo tailscale up --authkey=your-auth-key
```

**Pods Not Starting**
```bash
# Check pod status and events
kubectl get pods -A
kubectl describe pod -n <namespace> <pod-name>

# Check storage
df -h /opt/k3s-storage
```

**DNS Resolution Issues**
```bash
# Check if external DNS works
nslookup your-domain.com

# Check internal DNS
kubectl get services -n kube-system
```

**Storage Permission Issues**
```bash
# Fix storage permissions
sudo chown -R $USER:$USER /path/to/your/data
sudo chmod -R 755 /path/to/your/data
```

### Recovery Procedures

**Start Over (Clean Installation)**
```bash
# Remove K3s completely
sudo /usr/local/bin/k3s-uninstall.sh

# Clean up storage
sudo rm -rf /opt/k3s-storage/*

# Re-run installation
./scripts/homelab.sh setup-all
```

**Partial Recovery (Applications Only)**
```bash
# Redeploy applications without system setup
./scripts/homelab.sh deploy
```

### Verification Commands

**System Health Check**
```bash
# All-in-one status check
./scripts/homelab.sh status

# Individual checks
systemctl status k3s
sudo tailscale status
kubectl get nodes
kubectl get pods -A
df -h
```

**Network Connectivity Test**
```bash
# Test internal connectivity
kubectl exec -it -n utilities deployment/whoami -- wget -qO- http://google.com

# Test external access (if VPS configured)
curl -I https://whoami.your-domain.com
```

**Service Functionality Test**
```bash
# Test each service endpoint
curl -k https://jellyfin.your-domain.com
curl -k https://sonarr.your-domain.com
curl -k https://radarr.your-domain.com
curl -k https://prowlarr.your-domain.com
curl -k https://qbittorrent.your-domain.com
curl -k https://drive.your-domain.com
```

## Next Steps

After successful installation:

1. **Read Operations Guide**: `docs/OPERATIONS.md` for daily management
2. **Configure Services**: Set up indexers, download clients, media libraries
3. **Setup Backups**: Configure Borgmatic for data protection
4. **Review Security**: Implement additional security measures as needed
5. **Monitor Health**: Set up regular health checking routines

## Support

If you encounter issues:

1. Check the **Troubleshooting Guide**: `docs/TROUBLESHOOTING.md`
2. Review logs: `./scripts/homelab.sh logs <service>`
3. Check cluster status: `./scripts/homelab.sh status`
4. Verify configuration: Review `config/homelab.env`

The installation process is designed to be idempotent - you can re-run scripts safely if issues occur.