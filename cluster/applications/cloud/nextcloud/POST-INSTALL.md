# Nextcloud Post-Installation Configuration

After deploying Nextcloud to k3s, run these commands to apply additional configuration settings.

## Required Settings

These settings should be applied after initial Nextcloud installation:

### 1. Trusted Proxies (Required for reverse proxy)

Nextcloud is behind Traefik reverse proxy. Configure trusted proxy ranges so it properly handles forwarded client IPs:

```bash
# Add k3s pod network (10.42.0.0/16)
kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set trusted_proxies 0 --value='10.42.0.0/16'"

# Add k3s service network (10.43.0.0/16)
kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set trusted_proxies 1 --value='10.43.0.0/16'"
```

**Why this matters:**
- Without trusted_proxies, Nextcloud sees all requests coming from the proxy IP
- Breaks security logs, access control, and IP-based features
- Required for proper client IP logging

### 2. Maintenance Window (Recommended)

Set background job execution window to 3 AM (aligns with backup schedule):

```bash
kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set maintenance_window_start --value='1' --type=integer"
```

**Why this matters:**
- Coordinates with borgmatic backup (3:00 AM) and SnapRAID sync (2:00 AM)
- Background jobs won't interfere with backup operations
- Value `1` means 1:00 AM to 5:00 AM window

### 3. Default Phone Region (Nice to have)

Set default region for phone number formatting (Switzerland):

```bash
kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "php /var/www/html/occ config:system:set default_phone_region --value='CH'"
```

**Why this matters:**
- Proper phone number formatting in contacts
- Users in Switzerland get correct validation

## Verification

Check that settings were applied:

```bash
kubectl exec -n cloud deployment/nextcloud -- cat /var/www/html/config/config.php | grep -E "trusted_proxies|maintenance_window|default_phone" -A 5
```

Expected output:
```php
  'trusted_proxies' =>
  array (
    0 => '10.42.0.0/16',
    1 => '10.43.0.0/16',
  ),
  'maintenance_window_start' => 1,
  'default_phone_region' => 'CH',
```

## Apply All at Once

```bash
# Run all configuration commands
kubectl exec -n cloud deployment/nextcloud -- su -s /bin/bash www-data -c "
  php /var/www/html/occ config:system:set trusted_proxies 0 --value='10.42.0.0/16' && \
  php /var/www/html/occ config:system:set trusted_proxies 1 --value='10.43.0.0/16' && \
  php /var/www/html/occ config:system:set maintenance_window_start --value='1' --type=integer && \
  php /var/www/html/occ config:system:set default_phone_region --value='CH'
"
```

## When to Apply

These settings should be applied:
1. **After initial Nextcloud installation** (first deployment)
2. **After major upgrades** (settings usually persist but verify)
3. **After restoring from backup** (if config.php was overwritten)
4. **If Nextcloud pod is recreated** and persistent volume was lost

## Notes

- These settings are stored in `/var/www/html/config/config.php`
- The config file is in the Nextcloud app volume, so it persists across pod restarts
- If you need to reset Nextcloud completely, these must be reapplied
- Settings were migrated from old Docker setup's `custom-config.php`

## Historical Context

These settings were originally in the Docker deployment's `custom-config.php`:
- **trusted_proxies**: Updated from Docker network ranges to k3s ranges
- **maintenance_window_start**: Kept same value (3 AM)
- **default_phone_region**: Changed from 'US' to 'CH' per requirements

For more details, see: `MIGRATION-COMPARISON.md`
