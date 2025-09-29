# Node Setup Instructions for cyl-yoga213

## Prerequisites
- Fresh Debian-based system
- Network connectivity to this server
- Tailscale auth key

## Setup Steps

1. **Copy homelab repository to new node:**
   ```bash
   scp -r /home/cyl user@cyl-yoga213:~/homelab
   ```

2. **SSH to the new node:**
   ```bash
   ssh user@cyl-yoga213
   cd ~/homelab
   ```

3. **Configuration is ready:**
   ```bash
   # Config with secrets already created: nodes/cyl-yoga213/config.env.local
   # Template available at: nodes/cyl-yoga213/config.env
   # No editing needed - secrets copied from server
   ```

4. **Run setup scripts:**
   ```bash
   # System setup
   ./scripts/setup-system.sh

   # Cluster join
   ./scripts/setup-cluster.sh
   ```

5. **Verify node joined:**
   ```bash
   # On server node:
   kubectl get nodes
   ```

## Configuration Details
- Server URL: https://100.93.141.39:6443
- Cluster Token: K10d5d01fdabe22f8e35... (truncated)
- Node Role: agent

## Troubleshooting
- Ensure Tailscale is connected: `tailscale status`
- Check K3s logs: `sudo journalctl -u k3s-agent`
- Verify network connectivity: `ping 100.93.141.39`
