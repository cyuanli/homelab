#!/usr/bin/env bash
# Monitoring Setup Script
# Configures disk monitoring and backup notifications
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

main() {
    set_error_handling
    check_not_root

    log_step "Setting up monitoring systems"

    # Load configuration
    load_config

    log_step "1. Configuring disk monitoring"
    setup_disk_monitoring

    log_step "2. Configuring backup monitoring"
    setup_backup_monitoring

    log_step "3. Testing monitoring systems"
    test_monitoring

    log_success "Monitoring setup completed successfully!"
    show_monitoring_info
}

setup_disk_monitoring() {
    if [[ "${ENABLE_DISK_MONITORING:-true}" != "true" ]]; then
        log_info "Disk monitoring disabled in configuration, skipping"
        return 0
    fi

    # Check if SnapRAID storage is configured
    if [[ ! -d "${DATA_ROOT:-/media/data}" ]]; then
        log_warning "Data root directory not found: ${DATA_ROOT:-/media/data}"
        log_warning "Disk monitoring is designed for SnapRAID + MergerFS arrays"
        return 0
    fi

    log_info "Setting up disk health monitoring for SnapRAID storage"

    # Create monitoring configuration if it doesn't exist
    local monitoring_config="$HOMELAB_ROOT/config/service-configs/monitoring.conf"
    if [[ ! -f "$monitoring_config" ]]; then
        log_info "Creating monitoring configuration from template"
        cp "$HOMELAB_ROOT/config/service-configs/monitoring.conf.template" "$monitoring_config"

        log_warning "Please customize the monitoring configuration:"
        log_warning "  Edit: $monitoring_config"
        log_warning "  Update drive configuration for your system"
    fi

    # Setup cron job for monitoring
    local cron_job="*/5 * * * * $SCRIPT_DIR/monitor-storage.sh check >/dev/null 2>&1"

    # Check if cron job already exists
    if ! crontab -l 2>/dev/null | grep -q "monitor-storage.sh"; then
        log_info "Adding disk monitoring cron job (runs every 5 minutes)"
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log_success "Disk monitoring cron job added"
    else
        log_info "Disk monitoring cron job already configured"
    fi

    # Test the monitoring system
    log_info "Testing disk monitoring system"
    if "$SCRIPT_DIR/monitor-storage.sh" status >/dev/null 2>&1; then
        log_success "Disk monitoring system operational"
    else
        log_warning "Disk monitoring test failed - check configuration"
    fi
}

setup_backup_monitoring() {
    if [[ "${ENABLE_BACKUP_MONITORING:-true}" != "true" ]]; then
        log_info "Backup monitoring disabled in configuration, skipping"
        return 0
    fi

    if ! command_exists borgmatic; then
        log_info "Borgmatic not installed, skipping backup monitoring setup"
        return 0
    fi

    log_info "Setting up backup monitoring with Borgmatic"

    # Create borgmatic hooks directory
    local hooks_dir="/etc/borgmatic/hooks"
    sudo mkdir -p "$hooks_dir"

    # Install notification script
    sudo cp "$SCRIPT_DIR/backup-notify.sh" "$hooks_dir/"
    sudo chmod +x "$hooks_dir/backup-notify.sh"

    # Create borgmatic configuration template if it doesn't exist
    local borgmatic_config="/etc/borgmatic/config.yaml"
    if [[ ! -f "$borgmatic_config" ]]; then
        log_info "Creating borgmatic configuration template"
        sudo tee "$borgmatic_config" > /dev/null << 'EOF'
# Borgmatic configuration for homelab backups
# Customize for your backup destinations and requirements

location:
    source_directories:
        - /home
        - /opt/k3s-storage
        - /etc/borgmatic
        - /etc/rancher/k3s

    repositories:
        # Add your backup repositories here
        # Example:
        # - user@backup-server:homelab-backups

    one_file_system: true
    exclude_patterns:
        - '*.tmp'
        - '*.cache'
        - '*.log'
        - 'node_modules'
        - '__pycache__'

storage:
    encryption_passphrase: "your-encryption-passphrase-here"
    compression: auto

retention:
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 6

hooks:
    on_error:
        - /etc/borgmatic/hooks/backup-notify.sh exit-code
    after_backup:
        - /etc/borgmatic/hooks/backup-notify.sh success
EOF

        log_warning "Please customize the borgmatic configuration:"
        log_warning "  Edit: $borgmatic_config"
        log_warning "  Set your backup repositories and encryption passphrase"
    fi

    # Create systemd service files
    local systemd_dir="/etc/systemd/system"

    # Borgmatic service
    sudo tee "$systemd_dir/borgmatic.service" > /dev/null << 'EOF'
[Unit]
Description=Borgmatic backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/borgmatic --verbosity 1
EOF

    # Borgmatic timer
    sudo tee "$systemd_dir/borgmatic.timer" > /dev/null << 'EOF'
[Unit]
Description=Run borgmatic backup daily
Requires=borgmatic.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd and enable timer
    sudo systemctl daemon-reload
    sudo systemctl enable borgmatic.timer

    log_info "Borgmatic backup monitoring configured"
    log_info "Enable with: sudo systemctl start borgmatic.timer"
}

test_monitoring() {
    log_info "Testing monitoring systems"

    # Test disk monitoring if enabled
    if [[ "${ENABLE_DISK_MONITORING:-true}" == "true" ]]; then
        if command_exists "$SCRIPT_DIR/monitor-storage.sh"; then
            log_info "Testing disk monitoring alert system"
            if "$SCRIPT_DIR/monitor-storage.sh" status >/dev/null 2>&1; then
                log_success "Disk monitoring operational"
            else
                log_warning "Disk monitoring may need configuration"
            fi
        fi
    fi

    # Test backup monitoring if enabled
    if [[ "${ENABLE_BACKUP_MONITORING:-true}" == "true" ]] && command_exists borgmatic; then
        log_info "Testing backup notification system"
        if [[ -x "/etc/borgmatic/hooks/backup-notify.sh" ]]; then
            log_success "Backup notifications configured"
        else
            log_warning "Backup notification script not found"
        fi
    fi
}

show_monitoring_info() {
    cat << EOF

${GREEN}✅ Monitoring setup completed!${NC}

${BLUE}Monitoring Status:${NC}

EOF

    # Disk monitoring status
    if [[ "${ENABLE_DISK_MONITORING:-true}" == "true" ]]; then
        echo "${GREEN}✅ Disk Health Monitoring${NC}"
        echo "  - SMART health monitoring enabled"
        echo "  - Automatic failure detection every 5 minutes"
        echo "  - Emergency service shutdown on drive failure"
        echo "  - Array lockdown (read-only) protection"

        local monitoring_config="$HOMELAB_ROOT/config/service-configs/monitoring.conf"
        if [[ -f "$monitoring_config" ]]; then
            echo "  - Configuration: $monitoring_config"
        fi
        echo "  - Alerts: Prometheus/Alertmanager"
    else
        echo "${YELLOW}⚠ Disk Health Monitoring: Disabled${NC}"
    fi

    echo ""

    # Backup monitoring status
    if [[ "${ENABLE_BACKUP_MONITORING:-true}" == "true" ]]; then
        if command_exists borgmatic; then
            echo "${GREEN}✅ Backup Monitoring${NC}"
            echo "  - Borgmatic integration enabled"
            echo "  - Systemd timer configured"
            echo "  - Metrics exported to Prometheus"

            if systemctl is-enabled borgmatic.timer >/dev/null 2>&1; then
                echo "  - Timer: ${GREEN}Enabled${NC}"
            else
                echo "  - Timer: ${YELLOW}Disabled${NC} (run: sudo systemctl start borgmatic.timer)"
            fi
        else
            echo "${YELLOW}⚠ Backup Monitoring: Borgmatic not installed${NC}"
        fi
    else
        echo "${YELLOW}⚠ Backup Monitoring: Disabled${NC}"
    fi

    cat << EOF

${BLUE}Configuration Files:${NC}
- Disk monitoring: $HOMELAB_ROOT/config/service-configs/monitoring.conf
- Backup config: /etc/borgmatic/config.yaml
- Alert rules: cluster/applications/monitoring/prometheus/alerts.yaml
- Alertmanager: cluster/applications/monitoring/alertmanager/alertmanager.yaml

${BLUE}Management Commands:${NC}
- Check disk status: ${CYAN}./scripts/monitor-storage.sh status${NC}
- View disk metrics: ${CYAN}cat /var/lib/node_exporter/textfile_collector/disk_monitor.prom${NC}
- Check backup status: ${CYAN}sudo systemctl status borgmatic.timer${NC}
- Run backup manually: ${CYAN}sudo borgmatic --verbosity 1${NC}

EOF
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi