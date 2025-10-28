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
    local lan_cidr="${LAN_CIDR:-192.168.1.0/24}"

    if [[ ! -d "$data_root" ]]; then
        log_error "Data root directory not found: $data_root"
        log_error "Please create the directory first or update DATA_ROOT in config"
        exit 1
    fi

    log_info "Configuring NFS exports for $data_root"

    # Check if export already exists
    if grep -q "^$data_root " /etc/exports 2>/dev/null; then
        log_info "NFS export already configured"
        return 0
    fi

    # Add NFS export
    local export_line="$data_root $lan_cidr(rw,sync,no_subtree_check,no_root_squash,fsid=0)"
    log_info "Adding export: $export_line"

    echo "" | sudo tee -a /etc/exports >/dev/null
    echo "# K3s cluster storage" | sudo tee -a /etc/exports >/dev/null
    echo "$export_line" | sudo tee -a /etc/exports >/dev/null

    # Apply exports
    log_info "Applying NFS exports"
    sudo exportfs -ra

    # Verify export
    log_info "Verifying NFS exports"
    sudo exportfs -v

    log_success "NFS exports configured"
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
