# Homelab Architecture

This document provides a detailed technical overview of the homelab infrastructure architecture, design decisions, and component relationships.

## Overview

The homelab consists of a hybrid architecture combining:
- **K3s Cluster**: Lightweight Kubernetes running containerized applications
- **VPS Proxy**: Public-facing reverse proxy for external access
- **Tailscale Mesh**: Secure WireGuard-based networking layer
- **Storage Layer**: Local persistent storage with monitoring and protection

## Network Architecture

### High-Level Flow
```
Internet Users
    ↓
VPS (Public IP)
    ↓ (Nginx Stream Proxy)
Tailscale Tunnel (Encrypted WireGuard)
    ↓
Homelab K3s Cluster
    ↓ (Traefik Ingress)
Applications (Pods)
```

### Network Segments

**1. Public Internet Layer**
- **Entry Point**: VPS with public IPv4 address
- **DNS**: A records pointing domains to VPS IP
- **Protocols**: HTTP/HTTPS (80/443), SSH passthrough (51422)

**2. VPS Proxy Layer**
- **Technology**: Nginx stream module
- **Function**: TCP/UDP stream forwarding
- **Features**: Proxy protocol support, real IP preservation
- **Security**: UFW firewall, SSH key authentication only

**3. Tailscale Mesh Network**
- **Protocol**: WireGuard with Tailscale coordination
- **Encryption**: ChaCha20-Poly1305 authenticated encryption
- **Addressing**: Tailscale assigns 100.x.x.x subnet
- **Features**: Automatic key rotation, NAT traversal, mesh topology

**4. K3s Cluster Network**
- **CNI**: Flannel (K3s default)
- **Pod Network**: 10.42.0.0/16 (default K3s range)
- **Service Network**: 10.43.0.0/16 (default K3s range)
- **Ingress**: Traefik with automatic service discovery

**5. Application Layer**
- **Isolation**: Kubernetes namespaces (media, cloud, utilities, etc.)
- **Communication**: Service mesh via Kubernetes services
- **Storage**: Persistent volumes on local filesystem

## Component Architecture

### K3s Cluster Components

**Control Plane (Single Node)**
- **API Server**: Kubernetes API with Tailscale networking
- **etcd**: Embedded SQLite database (K3s default)
- **Controller Manager**: Standard Kubernetes controllers
- **Scheduler**: Pod scheduling and placement

**Worker Components**
- **kubelet**: Container lifecycle management
- **kube-proxy**: Service networking and load balancing
- **Flannel**: CNI for pod networking
- **Local Path Provisioner**: Dynamic PV provisioning

**Ingress Layer**
- **Traefik**: Cloud-native ingress controller
- **Features**: Automatic HTTPS, service discovery, dashboard
- **Certificates**: Let's Encrypt ACME integration
- **Backends**: Kubernetes service discovery

### Application Architecture

**Media Stack (Namespace: media)**
```
Prowlarr (Indexer Management)
    ↓ (provides indexers)
Sonarr/Radarr (Content Management)
    ↓ (requests downloads)
qBittorrent (Download Client)
    ↓ (downloads to shared storage)
Jellyfin (Media Server)
    ↓ (serves content)
Users
```

**Cloud Stack (Namespace: cloud)**
```
Nextcloud (Web Application)
    ↓ (uses)
PostgreSQL (Database)
    ↓ (caching via)
Redis (Cache Layer)
    ↓ (stores data on)
Persistent Volumes
```

**Monitoring Stack**
```
Storage Monitor (Host Process)
    ↓ (monitors)
Storage Drives
    ↓ (alerts via)
Discord Webhooks
    ↓ (stops workloads on failure)
K8s API / Docker API
```

## Storage Architecture

### Storage Layers

**1. Physical Storage**
- **Data Drives**: Multiple drives mounted at `/mnt/data*`
- **Configuration**: Device-specific mount points
- **Protection**: SnapRAID parity (configurable)

**2. Logical Storage**
- **MergerFS Pool**: Unified view at `/mnt/storage` (optional)
- **Application Data**: `/media/data/` for shared content
- **System Data**: `/opt/k3s-storage/` for K8s persistent volumes

**3. Kubernetes Storage**
- **StorageClass**: local-path (K3s default)
- **Provisioner**: Local Path Provisioner
- **Access Modes**: ReadWriteOnce (local volumes)
- **Persistence**: Host path mounts with proper ownership

### Storage Monitoring

**Monitor Process**
- **Technology**: Bash script with systemd service
- **Frequency**: Configurable interval (default 5 minutes)
- **Checks**: Mount point availability, drive accessibility
- **Actions**: Workload shutdown, Discord notifications

**Protection Mechanism**
```
Drive Failure Detected
    ↓
Stop All Workloads
    ↓ (K8s)
Scale Deployments to 0
    ↓ (Docker - if applicable)
Stop Containers
    ↓
Send Discord Alert
    ↓
Log Event
```

## Security Architecture

### Network Security

**Perimeter Security**
- **VPS Firewall**: UFW allowing only required ports
- **SSH Access**: Key-based authentication only
- **Rate Limiting**: Nginx connection limits

**Mesh Security**
- **Encryption**: WireGuard protocol end-to-end
- **Authentication**: Tailscale key-based device authentication
- **Access Control**: Tailscale ACLs (configurable)

**Cluster Security**
- **API Access**: kubectl via kubeconfig file
- **Service Isolation**: Kubernetes namespace boundaries
- **Network Policies**: Configurable (currently permissive)

### Application Security

**Authentication Layers**
1. **External**: DNS + SSL certificates
2. **Proxy**: VPS nginx stream forwarding
3. **Ingress**: Traefik with automatic HTTPS
4. **Application**: Service-specific authentication

**Certificate Management**
- **Provider**: Let's Encrypt ACME
- **Automation**: Traefik automatic provisioning
- **Storage**: Kubernetes secrets + persistent volumes
- **Renewal**: Automatic via Traefik

**Secret Management**
- **K8s Secrets**: Base64 encoded secrets in cluster
- **ConfigMaps**: Non-sensitive configuration
- **File Mounts**: Config files mounted as volumes

## Scalability Design

### Horizontal Scaling

**Node Addition**
- **Process**: Tailscale mesh + K3s agent join
- **Automation**: Scripts for configuration and setup
- **Load Distribution**: Kubernetes scheduler placement

**Service Scaling**
- **Stateless Services**: Can be replicated (Jellyfin, Nextcloud app)
- **Stateful Services**: Single instance with persistent storage
- **Load Balancing**: Kubernetes services + Traefik

### Vertical Scaling

**Resource Allocation**
- **CPU/Memory**: Kubernetes resource requests/limits
- **Storage**: Persistent volume expansion (manual)
- **Network**: Tailscale mesh scales automatically

### Limitations

**Single Points of Failure**
- **Storage**: Local storage limits availability
- **Database**: Single PostgreSQL instance
- **Ingress**: Single Traefik instance (can be scaled)

**Mitigation Strategies**
- **Backups**: Borgmatic for data protection
- **Monitoring**: Storage health monitoring
- **Recovery**: Documented recovery procedures

## Configuration Management

### Configuration Hierarchy

**1. Infrastructure Configuration**
- **File**: `config/homelab.env`
- **Scope**: System-wide settings
- **Examples**: Domain, storage paths, user IDs

**2. Service Configuration**
- **Location**: `config/service-configs/`
- **Scope**: Service-specific settings
- **Examples**: Authentication, monitoring webhooks

**3. K8s Configuration**
- **Location**: `cluster/applications/`
- **Technology**: Kustomize overlays
- **Scope**: Application deployment manifests

**4. Node Configuration**
- **Location**: `nodes/<hostname>/`
- **Scope**: Node-specific settings
- **Examples**: Cluster role, tokens

### Configuration Flow
```
homelab.env (Global)
    ↓ (sourced by)
Setup Scripts
    ↓ (generates)
Service Configs
    ↓ (used by)
K8s Manifests
    ↓ (deployed to)
Running Applications
```

## Deployment Architecture

### Bootstrap Process

**1. System Preparation**
- Package installation (Docker, curl, git)
- User and permission setup
- Firewall configuration
- Tailscale installation and authentication

**2. Cluster Initialization**
- K3s installation with Tailscale networking
- kubectl configuration
- Kustomize installation
- Core infrastructure deployment

**3. Application Deployment**
- Namespace creation
- Secret provisioning
- Application manifests deployment
- Health checking and validation

### Update Process

**Rolling Updates**
- **K8s Native**: Deployment rolling updates
- **Image Updates**: Container image tag changes
- **Configuration Updates**: ConfigMap/Secret updates trigger restarts

**Maintenance Windows**
- **Planned**: System package updates
- **Emergency**: Storage failure response
- **Coordination**: Discord notifications

## Monitoring & Observability

### Monitoring Stack

**Infrastructure Monitoring**
- **Storage**: Custom bash script monitoring
- **Network**: Tailscale status monitoring
- **Services**: Kubernetes health checks

**Application Monitoring**
- **Health Checks**: K8s liveness/readiness probes
- **Logs**: kubectl logs + container logging
- **Metrics**: Basic resource usage via kubectl

**Alerting**
- **Channel**: Discord webhooks
- **Events**: Storage failures, service failures
- **Escalation**: Manual intervention required

### Log Architecture

**Log Sources**
- **System**: journalctl (systemd services)
- **K3s**: K3s server logs
- **Applications**: Container stdout/stderr
- **Storage Monitor**: Custom log files

**Log Management**
- **Retention**: Default container log rotation
- **Access**: kubectl logs command
- **Aggregation**: No centralized logging (future enhancement)

## Future Architecture Considerations

### Planned Enhancements

**High Availability**
- Multi-node K3s cluster
- External database (PostgreSQL cluster)
- Distributed storage (Longhorn, Ceph)

**Monitoring Improvements**
- Prometheus + Grafana stack
- Centralized logging (ELK/Loki)
- Advanced alerting (AlertManager)

**Security Hardening**
- Network policies implementation
- Pod security policies
- Secret management improvements (External Secrets, Vault)

### Scalability Roadmap

**Near Term**
- Additional worker nodes
- Service replicas for stateless apps
- Storage expansion

**Long Term**
- Multi-site deployment
- Edge computing integration
- Service mesh (Istio/Linkerd)

This architecture provides a solid foundation for a homelab environment while maintaining simplicity and operability. The design prioritizes automation, security, and maintainability over complex enterprise features.