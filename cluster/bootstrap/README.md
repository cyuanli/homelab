# K3s Bootstrap

Scripts for setting up the K3s cluster.

## Prerequisites

1. Create node-specific config files in the repository root:
   ```bash
   # For the first server node (from repository root)
   mkdir -p nodes/node1
   cat > nodes/node1/config.env << EOF
   NODE_ROLE=server
   CLUSTER_TOKEN=your-super-secret-token-here
   TAILSCALE_AUTHKEY=tskey-auth-xxxxx
   EOF

   # For additional nodes (from repository root)
   mkdir -p nodes/node2
   cat > nodes/node2/config.env << EOF
   NODE_ROLE=agent
   CLUSTER_TOKEN=your-super-secret-token-here
   SERVER_URL=https://FIRST_NODE_TAILSCALE_IP:6443
   TAILSCALE_AUTHKEY=tskey-auth-xxxxx
   EOF
   ```

2. Ensure each machine can reach the others via Tailscale

## Installation

### Automated Approach (Recommended)

For adding nodes to an existing cluster, use the management script:

```bash
# On existing server node
./scripts/manage-nodes.sh add <new-hostname>
# Follow the printed instructions
```

### Manual Approach

1. On the first node (server):
   ```bash
   chmod +x cluster/bootstrap/k3s-install.sh
   ./cluster/bootstrap/k3s-install.sh
   ```

2. Copy the kubeconfig to manage the cluster remotely:
   ```bash
   # The script will output the node token and server URL
   # Use these values in other nodes' config.env files
   ```

3. On additional nodes:
   ```bash
   # Update their config.env with the correct SERVER_URL
   ./cluster/bootstrap/k3s-install.sh
   ```

4. Verify the cluster:
   ```bash
   kubectl get nodes -o wide
   ```

## Post-Installation

After all nodes are joined, deploy the core infrastructure:
```bash
kubectl apply -f cluster/manifests/namespaces/
kubectl apply -f cluster/manifests/traefik/
kubectl apply -f cluster/manifests/cert-manager/
```