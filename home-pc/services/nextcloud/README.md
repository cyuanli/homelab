# Nextcloud All-in-One Service

This service deploys Nextcloud All-in-One (AIO) behind Traefik with automatic HTTPS.

## Important Setup Notes

⚠️ **Critical**: Nextcloud All-in-One is complex and requires careful setup. Read this entire document before deploying.

### Prerequisites

1. **Domain Name**: You MUST have a valid domain name pointing to your VPS. IP addresses are not supported.
2. **Internet Access**: Nextcloud AIO requires internet connectivity and cannot run completely offline.
3. **DNS Configuration**: Ensure your domain points to your VPS public IP.

### Configuration Steps

1. **Domain Configuration**: The service is pre-configured for `drive.cliff.li`.

2. **Deploy the Service**:
   ```bash
   cd ~/homelab/home-pc/services/nextcloud
   docker-compose up -d
   ```

3. **Access AIO Admin Interface**:
   - Local access: `http://localhost:8080` (on home PC)
   - Or via Traefik: `http://nextcloud-admin.local` (if configured in your local DNS)

4. **Initial Setup**:
   - Access the AIO admin interface
   - Enter your domain name: `drive.cliff.li`
   - Configure your desired apps and settings
   - Start the Nextcloud containers

5. **Access Nextcloud**:
   - Once setup is complete: `https://drive.cliff.li`

### Network Architecture

```
Internet → VPS (Nginx) → Tailscale → Home PC (Traefik) → Nextcloud AIO
```

The setup includes:
- **Master Container**: Management interface (port 8080)
- **Apache Container**: Main Nextcloud instance (port 11000 → 443)
- **Additional Containers**: Database, Redis, etc. (managed by AIO)

### Port Configuration

- **8080**: AIO admin interface (local access)
- **11000**: Apache container (proxied by Traefik to 443)
- **Additional ports**: Managed automatically by AIO for Talk, etc.

### Important Environment Variables

- `APACHE_PORT=11000`: Internal port for the Apache container
- `APACHE_IP_BINDING=0.0.0.0`: Allow connections from Traefik
- `SKIP_DOMAIN_VALIDATION=false`: Validate domain (set to `true` if issues)
- `TIMEZONE`: Set your timezone for proper scheduling

### Traefik Configuration Explained

The service uses specific Traefik labels to:
- Route `drive.cliff.li` to the Apache container (port 11000)
- Use HTTPS with Let's Encrypt certificates
- Pass through real client IPs with proper headers
- Optionally expose the admin interface locally

### Data Persistence

By default, data is stored in Docker volumes. To use a specific directory:

1. Uncomment the volume mapping in `docker-compose.yml`:
   ```yaml
   volumes:
     - /path/to/nextcloud/data:/mnt/ncdata
   ```

2. Create the directory with proper permissions:
   ```bash
   sudo mkdir -p /path/to/nextcloud/data
   sudo chown -R www-data:www-data /path/to/nextcloud/data
   ```

### Troubleshooting

#### Domain Validation Issues
If you see domain validation errors:
1. Verify DNS points to your VPS
2. Check that the domain is accessible from the internet
3. Temporarily set `SKIP_DOMAIN_VALIDATION=true`

#### Container Communication Issues
If the AIO can't reach the Apache container:
1. Check Docker networking: `docker network ls`
2. Verify the traefik network exists: `docker network inspect traefik`
3. Check container logs: `docker logs nextcloud-aio-mastercontainer`

#### SSL/Certificate Issues
- AIO handles SSL internally - don't configure SSL in the master container
- Traefik handles external SSL with Let's Encrypt
- The Apache container serves HTTPS on port 11000

### Backup Considerations

Nextcloud AIO includes built-in backup functionality:
1. Configure backup location in the AIO interface
2. Set up automated backup schedules
3. Consider backing up the entire Docker volume as well

### Security Notes

- The master container needs Docker socket access (required for AIO)
- All containers run in the same Docker network for service discovery
- External access is controlled by Traefik with proper SSL termination
- Consider additional security measures for production use

### Updates

Nextcloud AIO handles updates automatically:
1. Updates are managed through the AIO interface
2. The master container will pull new versions as needed
3. Manual updates: recreate the master container with latest image

### Resources

- [Nextcloud All-in-One GitHub](https://github.com/nextcloud/all-in-one)
- [Reverse Proxy Documentation](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md)
- [Nextcloud Documentation](https://docs.nextcloud.com/)