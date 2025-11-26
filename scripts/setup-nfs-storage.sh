#!/usr/bin/env bash
# NFS Storage Setup Script
# Sets up NFS server on storage node and NFS clients on all nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

main() {
    set_error_handling
    check_not_root

    log_step "Setting up NFS storage"

    # Load configuration
    load_config

    # Check required variables
    check_required_vars "HOMELAB_USER"

    # Determine if this is a storage node
    local is_storage_node="${IS_STORAGE_NODE:-false}"
    if [[ "$(hostname)" == "${STORAGE_NODE:-cyl-homelab}" ]]; then
        is_storage_node="true"
    fi

    if [[ "$is_storage_node" == "true" ]]; then
        log_step "1. Setting up NFS server (storage node)"
        setup_nfs_server

        log_step "2. Configuring NFS exports"
        configure_nfs_exports

        log_step "3. Configuring firewall for NFS"
        configure_nfs_firewall
    else
        log_info "Not a storage node, skipping NFS server setup"
    fi

    log_step "4. Installing NFS client utilities"
    install_nfs_client

    log_success "NFS storage setup completed successfully!"
    show_next_steps "$is_storage_node"
}

setup_nfs_server() {
    if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
        log_info "NFS server already installed and running"
        return 0
    fi

    log_info "Installing NFS kernel server"
    sudo apt update
    sudo apt install -y nfs-kernel-server

    log_info "Enabling NFS server service"
    ensure_service_enabled nfs-kernel-server

    log_success "NFS server installed"
}

configure_nfs_exports() {
    local data_root="${DATA_ROOT:-/media/data}"
    local configs_root="${K3S_CONFIGS_ROOT:-/srv/k3s-configs}"
    local exports_root="/exports"

    # Check required directories exist
    for dir in "$data_root" "$configs_root"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Required directory not found: $dir"
            log_error "Please create the directory first or update config"
            exit 1
        fi
    done

    log_info "Setting up NFSv4 bind mount structure"

    # Create exports root
    if [[ ! -d "$exports_root" ]]; then
        log_info "Creating $exports_root directory"
        sudo mkdir -p "$exports_root"
    fi

    # Create bind mount points
    sudo mkdir -p "$exports_root/media" "$exports_root/configs"

    # Set up bind mounts
    log_info "Configuring bind mounts"

    # Check if bind mounts already exist in /etc/fstab
    if ! grep -q "$data_root $exports_root/media" /etc/fstab; then
        log_info "Adding bind mount for $data_root"
        echo "$data_root $exports_root/media none bind 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi

    if ! grep -q "$configs_root $exports_root/configs" /etc/fstab; then
        log_info "Adding bind mount for $configs_root"
        echo "$configs_root $exports_root/configs none bind 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi

    # Mount bind mounts if not already mounted
    if ! mountpoint -q "$exports_root/media"; then
        log_info "Mounting $exports_root/media"
        sudo mount --bind "$data_root" "$exports_root/media"
    fi

    if ! mountpoint -q "$exports_root/configs"; then
        log_info "Mounting $exports_root/configs"
        sudo mount --bind "$configs_root" "$exports_root/configs"
    fi

    log_info "Copying NFS exports configuration from config/system-configs/exports"

    # Use the tracked exports file if it exists
    local exports_config="$SCRIPT_DIR/../config/system-configs/exports"
    if [[ -f "$exports_config" ]]; then
        sudo cp "$exports_config" /etc/exports
    else
        log_error "Exports config file not found: $exports_config"
        exit 1
    fi

    # Apply exports
    log_info "Applying NFS exports"
    sudo exportfs -ra

    # Verify exports
    log_info "Verifying NFS exports"
    sudo exportfs -v

    log_success "NFS exports configured with bind mounts"
}

configure_nfs_firewall() {
    if [[ "${ENABLE_UFW:-true}" != "true" ]]; then
        log_info "UFW disabled in configuration, skipping firewall setup"
        return 0
    fi

    log_info "Configuring firewall for NFS"

    local lan_cidr="${LAN_CIDR:-192.168.0.0/16}"

    # Allow NFS ports
    log_info "Opening NFS ports for LAN: $lan_cidr"
    sudo ufw allow from "$lan_cidr" to any port 111 proto tcp comment 'NFS rpcbind'
    sudo ufw allow from "$lan_cidr" to any port 111 proto udp comment 'NFS rpcbind'
    sudo ufw allow from "$lan_cidr" to any port 2049 proto tcp comment 'NFS server'
    sudo ufw allow from "$lan_cidr" to any port 2049 proto udp comment 'NFS server'

    # Reload firewall
    sudo ufw reload

    log_success "Firewall configured for NFS"
}

install_nfs_client() {
    if dpkg -l | grep -q nfs-common; then
        log_info "NFS client utilities already installed"
        return 0
    fi

    log_info "Installing NFS client utilities"
    sudo apt update
    sudo apt install -y nfs-common

    log_success "NFS client utilities installed"
}

show_next_steps() {
    local is_storage_node="$1"

    cat << EOF

${GREEN}✅ NFS storage setup completed successfully!${NC}

EOF

    if [[ "$is_storage_node" == "true" ]]; then
        cat << EOF
${BLUE}NFS Server Configuration:${NC}
- Data root: ${DATA_ROOT:-/media/data}
- Export configured with fsid=0 (NFSv4 pseudo-root)
- Allowed network: ${LAN_CIDR:-192.168.1.0/24}
- Firewall ports opened: 111, 2049 (TCP/UDP)

${BLUE}Verify NFS server:${NC}
  ${CYAN}sudo exportfs -v${NC}
  ${CYAN}sudo systemctl status nfs-kernel-server${NC}

EOF
    fi

    cat << EOF
${BLUE}Next steps:${NC}

1. If this is the storage node, ensure data directories exist:
   ${CYAN}sudo mkdir -p ${DATA_ROOT:-/media/data}/{media/{movies,tv,music},downloads}${NC}
   ${CYAN}sudo mkdir -p ${DATA_ROOT:-/media/data}/k3s-configs/media-stack${NC}

2. Deploy NFS CSI driver to K3s cluster:
   ${CYAN}kubectl apply -f cluster/infrastructure/csi-driver-nfs/${NC}

3. Create NFS StorageClass:
   ${CYAN}kubectl apply -f cluster/infrastructure/storage/nfs-storageclass.yaml${NC}

4. Create media PVs and PVCs:
   ${CYAN}kubectl apply -f cluster/applications/media-stack/storage/${NC}

${BLUE}Test NFS from another node:${NC}
  ${CYAN}showmount -e ${STORAGE_NODE_IP:-192.168.1.94}${NC}

EOF
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
