#!/usr/bin/env bash
# Fresh System Setup Script
# Prepares a Debian-based system for homelab deployment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

main() {
    set_error_handling
    check_not_root

    log_step "Setting up homelab system"

    # Load configuration
    load_config

    # Check required variables
    check_required_vars "HOMELAB_USER" "DOMAIN"

    log_step "1. Updating system packages"
    update_system

    log_step "2. Installing core packages"
    install_core_packages

    log_step "3. Installing container runtime"
    install_container_runtime

    log_step "4. Installing Tailscale"
    install_tailscale

    log_step "5. Configuring firewall"
    configure_firewall

    log_step "6. Setting up user permissions"
    setup_user_permissions

    log_step "7. Creating directory structure"
    create_directory_structure

    log_step "8. Setting up NFS storage"
    setup_nfs_storage

    log_step "9. Installing Kubernetes tools"
    install_k8s_tools

    log_success "System setup completed successfully!"
    show_next_steps
}

update_system() {
    log_info "Updating package lists"
    sudo apt update

    log_info "Upgrading system packages"
    sudo apt upgrade -y

    log_info "Installing base utilities"
    sudo apt install -y curl wget git vim htop tree unzip jq
}

install_core_packages() {
    log_info "Installing monitoring tools"
    sudo apt install -y smartmontools sysstat iotop nethogs

    log_info "Installing network utilities"
    sudo apt install -y net-tools dnsutils

    log_info "Installing build essentials"
    sudo apt install -y build-essential

    log_info "Installing template processing tools"
    sudo apt install -y gettext-base

    # Install borgmatic if backup monitoring is enabled
    if [[ "${ENABLE_BACKUP_MONITORING:-false}" == "true" ]]; then
        log_info "Installing borgmatic for backup management"
        sudo apt install -y borgmatic
    fi
}

install_container_runtime() {
    if command_exists docker; then
        log_info "Docker already installed"
        return 0
    fi

    log_info "Installing Docker"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh

    log_info "Adding user to docker group"
    sudo usermod -aG docker "$HOMELAB_USER"

    log_info "Enabling Docker service"
    ensure_service_enabled docker

    log_info "Installing LXCFS for container resource visibility"
    sudo apt install -y lxcfs
    ensure_service_enabled lxcfs

    log_success "Docker installed successfully"
}

install_tailscale() {
    if command_exists tailscale; then
        log_info "Tailscale already installed"
    else
        log_info "Installing Tailscale"
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    log_info "Configuring Tailscale"
    if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
        log_info "Connecting to Tailscale with auth key"
        sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-routes
    else
        log_warning "No TAILSCALE_AUTHKEY provided"
        log_info "To connect manually: sudo tailscale up"
    fi

    # Detect VPS IP if configured
    if [[ -n "${VPS_HOSTNAME:-}" ]] && [[ -z "${VPS_IP:-}" ]]; then
        log_info "Detecting VPS Tailscale IP"
        local vps_ip
        if vps_ip=$(tailscale status --json | jq -r ".Peer[] | select(.HostName==\"$VPS_HOSTNAME\") | .TailscaleIPs[0]" 2>/dev/null); then
            if [[ "$vps_ip" != "null" && -n "$vps_ip" ]]; then
                log_info "Detected VPS IP: $vps_ip"
                export VPS_IP="$vps_ip"
            fi
        fi
    fi
}

configure_firewall() {
    if [[ "${ENABLE_UFW:-true}" != "true" ]]; then
        log_info "UFW disabled in configuration, skipping firewall setup"
        return 0
    fi

    if ! command_exists ufw; then
        log_info "Installing UFW"
        sudo apt install -y ufw
    fi

    log_info "Configuring UFW firewall"

    # Default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # Allow SSH from LAN if configured
    if [[ "${ALLOW_SSH_FROM_LAN:-true}" == "true" ]]; then
        local lan_cidr="${LAN_CIDR:-192.168.0.0/16}"
        log_info "Allowing SSH from LAN: $lan_cidr"
        sudo ufw allow from "$lan_cidr" to any port 22 proto tcp
    fi

    # Allow VPS access if configured
    if [[ -n "${VPS_IP:-}" ]]; then
        log_info "Allowing VPS access from: $VPS_IP"
        sudo ufw allow from "$VPS_IP" to any port 80,443 proto tcp
        sudo ufw allow from "$VPS_IP" to any port 443 proto udp
        sudo ufw allow from "$VPS_IP" to any port 22 proto tcp
    fi

    # Allow K3s ports for cluster communication
    log_info "Allowing K3s cluster ports"
    local lan_cidr="${LAN_CIDR:-192.168.0.0/16}"
    sudo ufw allow from "$lan_cidr" to any port 6443 proto tcp   # K3s API server
    sudo ufw allow from "$lan_cidr" to any port 2379 proto tcp   # etcd client
    sudo ufw allow from "$lan_cidr" to any port 2380 proto tcp   # etcd peer
    sudo ufw allow from "$lan_cidr" to any port 10250 proto tcp  # kubelet
    sudo ufw allow from "$lan_cidr" to any port 8472 proto udp   # Flannel VXLAN

    # Allow monitoring ports for Prometheus/Node Exporter
    log_info "Allowing monitoring ports"
    sudo ufw allow from "$lan_cidr" to any port 9100 proto tcp

    # Allow HTTP/HTTPS for services
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp

    # Enable firewall
    sudo ufw --force enable

    log_success "Firewall configured"
}

setup_user_permissions() {
    log_info "Setting up user permissions"

    # Create sudoers file for homelab operations
    local sudoers_file="/etc/sudoers.d/homelab-$HOMELAB_USER"
    sudo tee "$sudoers_file" > /dev/null << EOF
# Homelab permissions for $HOMELAB_USER
$HOMELAB_USER ALL=(ALL) NOPASSWD: /usr/local/bin/k3s*
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/systemctl
$HOMELAB_USER ALL=(ALL) NOPASSWD: /usr/bin/apt
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/mkdir
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/chown
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/chmod
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/mount
$HOMELAB_USER ALL=(ALL) NOPASSWD: /bin/umount
$HOMELAB_USER ALL=(ALL) NOPASSWD: /usr/bin/tailscale
EOF

    log_success "User permissions configured"
}

create_directory_structure() {
    log_info "Creating homelab directory structure"

    # Main homelab directories
    create_directory "/opt/homelab"
    create_directory "${K8S_STORAGE_ROOT:-/opt/k3s-storage}"

    # K8s persistent volume directories
    local storage_root="${K8S_STORAGE_ROOT:-/opt/k3s-storage}"
    create_directory "$storage_root/traefik-acme"
    create_directory "$storage_root/nextcloud-data"
    create_directory "$storage_root/nextcloud-files"
    create_directory "$storage_root/postgres-data"
    create_directory "$storage_root/redis-data"

    # Media directories (if they don't exist)
    if [[ -n "${DATA_ROOT:-}" ]]; then
        create_directory "${MEDIA_MOVIES:-$DATA_ROOT/media/movies}"
        create_directory "${MEDIA_TV:-$DATA_ROOT/media/tv}"
        create_directory "${MEDIA_MUSIC:-$DATA_ROOT/media/music}"
        create_directory "${DOWNLOADS_DIR:-$DATA_ROOT/downloads}"
    fi

    # User directories
    create_directory "/home/$HOMELAB_USER/backups"
    create_directory "/home/$HOMELAB_USER/Downloads/incomplete"

    log_success "Directory structure created"
}

setup_nfs_storage() {
    if [[ "${ENABLE_NFS_STORAGE:-true}" != "true" ]]; then
        log_info "NFS storage disabled in configuration, skipping"
        return 0
    fi

    log_info "Setting up NFS storage"

    # Run the NFS storage setup script
    if [[ -f "$SCRIPT_DIR/setup-nfs-storage.sh" ]]; then
        bash "$SCRIPT_DIR/setup-nfs-storage.sh"
    else
        log_warning "NFS storage setup script not found, skipping"
        log_info "To set up NFS manually, run: $SCRIPT_DIR/setup-nfs-storage.sh"
    fi
}

install_k8s_tools() {
    log_info "Installing Kubernetes tools"

    # Install kubectl
    local kubectl_version="${KUBECTL_VERSION:-v1.28.8}"
    if ! command_exists kubectl || ! kubectl version --client -o json | grep -q "$kubectl_version"; then
        log_info "Installing kubectl $kubectl_version"
        curl -LO "https://dl.k8s.io/release/$kubectl_version/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    else
        log_info "kubectl already installed"
    fi

    # Install Helm
    if ! command_exists helm; then
        log_info "Installing Helm"
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    else
        log_info "Helm already installed"
    fi

    log_success "Kubernetes tools installed"
}

show_next_steps() {
    cat << EOF

${GREEN}✅ System setup completed successfully!${NC}

System is now prepared for homelab deployment.

${BLUE}Next steps:${NC}

1. Setup K3s cluster:
   ${CYAN}./scripts/setup-cluster.sh${NC}

2. Deploy applications:
   ${CYAN}./scripts/deploy-applications.sh${NC}

3. Or run everything at once:
   ${CYAN}./scripts/homelab.sh setup-all${NC}

${BLUE}Configuration:${NC}
- User: $HOMELAB_USER
- Domain: $DOMAIN
- Storage root: ${K8S_STORAGE_ROOT:-/opt/k3s-storage}
- Data root: ${DATA_ROOT:-not configured}

${BLUE}Notes:${NC}
- You may need to log out and back in for Docker group membership to take effect
- If using Tailscale, ensure it's properly connected
- Update config/homelab.env.local as needed before proceeding

EOF
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi