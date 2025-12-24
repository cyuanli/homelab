#!/usr/bin/env bash
# Deploy NFS Stale Mount Prevention and Recovery Solution
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

main() {
    set_error_handling
    check_not_root

    log_step "Deploying NFS Stale Mount Prevention and Recovery Solution"

    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║       NFS Stale Mount Prevention and Recovery Deployment         ║
╚═══════════════════════════════════════════════════════════════════╝

This script will deploy:
1. Improved NFS mount options in StorageClass
2. NFS health monitoring script
3. Automated monitoring via cron
4. Kubernetes DaemonSet for distributed monitoring

EOF

    read -p "Continue with deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled"
        exit 0
    fi

    # Step 1: Update StorageClass
    log_step "1. Updating NFS StorageClass with improved mount options"

    log_info "Reviewing changes to StorageClass..."
    if git diff cluster/infrastructure/storage/nfs-storageclass.yaml | grep -q "timeo=150"; then
        log_info "Changes detected:"
        git diff cluster/infrastructure/storage/nfs-storageclass.yaml | grep -E "^\+.*timeo|^\+.*retrans|^\+.*actimeo" || true
    fi

    read -p "Apply updated StorageClass? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl apply -f cluster/infrastructure/storage/nfs-storageclass.yaml
        log_success "StorageClass updated"
    else
        log_info "Skipping StorageClass update"
    fi

    # Step 2: Install monitoring script
    log_step "2. Installing NFS health monitoring script"

    if [[ -x "$SCRIPT_DIR/monitor-nfs-health.sh" ]]; then
        log_success "Monitoring script already executable"
    else
        chmod +x "$SCRIPT_DIR/monitor-nfs-health.sh"
        log_success "Made monitoring script executable"
    fi

    # Test the script
    log_info "Testing monitoring script..."
    if sudo "$SCRIPT_DIR/monitor-nfs-health.sh" status; then
        log_success "Monitoring script test passed"
    else
        log_warning "Monitoring script test had issues (may be normal if NFS is degraded)"
    fi

    # Step 3: Setup cron job
    log_step "3. Setting up automated monitoring via cron"

    log_info "Checking for existing cron job..."
    if sudo crontab -l 2>/dev/null | grep -q "monitor-nfs-health.sh"; then
        log_info "Cron job already exists"
    else
        log_info "Installing cron job to run every 5 minutes..."

        # Create temporary file with new cron job
        local temp_cron=$(mktemp)
        sudo crontab -l 2>/dev/null > "$temp_cron" || true
        echo "*/5 * * * * $SCRIPT_DIR/monitor-nfs-health.sh check >> /var/log/nfs-health-monitor.log 2>&1" >> "$temp_cron"

        sudo crontab "$temp_cron"
        rm "$temp_cron"

        log_success "Cron job installed"
    fi

    # Verify cron job
    log_info "Installed cron jobs:"
    sudo crontab -l | grep nfs || log_warning "No NFS monitoring cron job found"

    # Step 4: Deploy Kubernetes DaemonSet
    log_step "4. Deploying Kubernetes DaemonSet for monitoring"

    read -p "Deploy DaemonSet to all nodes? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl apply -f cluster/applications/monitoring/nfs-health-monitor.yaml
        log_success "DaemonSet deployed"

        log_info "Waiting for DaemonSet pods to be ready..."
        kubectl rollout status daemonset/nfs-health-monitor -n kube-system --timeout=60s || true

        log_info "DaemonSet pod status:"
        kubectl get pods -n kube-system -l app=nfs-health-monitor
    else
        log_info "Skipping DaemonSet deployment"
    fi

    # Step 5: Summary
    log_step "5. Deployment Summary"

    cat << EOF

${GREEN}✅ Deployment Complete!${NC}

${BLUE}Components deployed:${NC}
✓ Improved NFS mount options (faster failure detection)
✓ NFS health monitoring script
✓ Automated cron job (every 5 minutes)
$(kubectl get daemonset nfs-health-monitor -n kube-system >/dev/null 2>&1 && echo "✓ Kubernetes DaemonSet" || echo "○ Kubernetes DaemonSet (skipped)")

${BLUE}Next Steps:${NC}

1. Monitor the logs:
   ${CYAN}sudo tail -f /var/log/nfs-health-monitor.log${NC}

2. Check current NFS health status:
   ${CYAN}sudo $SCRIPT_DIR/monitor-nfs-health.sh status${NC}

3. View Kubernetes DaemonSet logs:
   ${CYAN}kubectl logs -n kube-system -l app=nfs-health-monitor -f${NC}

4. Test manual recovery:
   ${CYAN}sudo $SCRIPT_DIR/monitor-nfs-health.sh recover${NC}

5. Add Prometheus alerts (optional):
   ${CYAN}See docs/NFS_STALE_MOUNT_SOLUTION.md for alert rules${NC}

${BLUE}Important Notes:${NC}

- Existing PVs still use old mount options. New mount options apply to:
  • New PVs created after this deployment
  • Existing PVs after pod restart

- To apply new options to existing PVs, restart affected pods:
  ${CYAN}kubectl rollout restart deployment -n <namespace> <deployment-name>${NC}

- The monitoring script runs every 5 minutes and will automatically:
  • Detect stale NFS mounts
  • Restart CSI driver if needed
  • Restart affected pods if needed

${BLUE}Documentation:${NC}
  ${CYAN}cat docs/NFS_STALE_MOUNT_SOLUTION.md${NC}

${BLUE}Monitoring:${NC}
  Metrics exported to: /var/lib/node_exporter/textfile_collector/nfs_health.prom

EOF

    log_success "All done! NFS stale mount prevention and recovery is now active."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
