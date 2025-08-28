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
- **Master Container**: Management interface (port 8080) - on `nextcloud-aio` network
- **Apache Container**: Main Nextcloud instance (port 11000 → 443) - on BOTH `nextcloud-aio` AND `traefik` networks
- **Additional Containers**: Database, Redis, etc. (managed by AIO) - on `nextcloud-aio` network

**Critical**: The `APACHE_ADDITIONAL_NETWORK=traefik` environment variable ensures the Apache container joins the traefik network, enabling reverse proxy connectivity while maintaining internal AIO network isolation.

### Port Configuration

- **8080**: AIO admin interface (local access)
- **11000**: Apache container (proxied by Traefik to 443)
- **Additional ports**: Managed automatically by AIO for Talk, etc.

### Important Environment Variables

- `APACHE_PORT=11000`: Internal port for the Apache container
- `APACHE_IP_BINDING=0.0.0.0`: Allow connections from Traefik
- `APACHE_ADDITIONAL_NETWORK=traefik`: Connect Apache container to traefik network (CRITICAL for reverse proxy)
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

This section documents **real issues we encountered** during setup. Use this as your debugging checklist.

#### 🚨 Port 8080 Conflict (CRITICAL ISSUE)

**Problem**: Nextcloud AIO master container and Traefik dashboard both want port 8080.

**Symptoms**:
```bash
# When you try to access Traefik API, you get Apache responses
curl http://localhost:8080  # Returns HTML, not JSON
docker port traefik         # Missing port 8080
```

**Root Cause**: Docker gives port 8080 to whichever container starts first.

**Solutions**:

*Option 1: Change Traefik API port (recommended):*
```yaml
# In traefik.yml
entryPoints:
  traefik:
    address: ":8090"

# In docker-compose.yml  
ports:
  - "8090:8090"
```

*Option 2: Change AIO master port:*
```yaml
# In nextcloud docker-compose.yml
ports:
  - "9080:8080"  # Instead of "8080:8080"
```

**Verification**: 
```bash
docker port traefik        # Should show 8090
curl http://localhost:8090/api/http/routers | jq keys  # Should return JSON
```

#### 🚨 Network Isolation Issue

**Problem**: Apache container only on `nextcloud-aio` network, Traefik can't reach it.

**Symptoms**:
- 502 Bad Gateway errors from external domain
- `docker inspect nextcloud-aio-apache` shows only one network

**Critical Fix**: Use correct environment variable name:
```yaml
environment:
  - APACHE_CONTAINER_ADDITIONAL_NETWORK=traefik  # NOT APACHE_ADDITIONAL_NETWORK
```

**Verification**:
```bash
docker inspect nextcloud-aio-apache | grep -A 20 "Networks"
# Must show BOTH 'nextcloud-aio' AND 'traefik' networks
```

#### 🚨 Static vs Dynamic Configuration

**Problem**: Docker labels don't work with AIO-managed containers.

**Why**: AIO creates containers dynamically, can't add custom labels.

**Solution**: Use Traefik file provider instead:

```yaml
# traefik/dynamic/nextcloud.yml
http:
  routers:
    nextcloud:
      rule: "Host(`drive.cliff.li`)"
      service: "nextcloud"
      entryPoints: ["websecure"]
      tls:
        certResolver: "letsencrypt"
  services:
    nextcloud:
      loadBalancer:
        servers:
          - url: "http://nextcloud-aio-apache:11000"  # Note: HTTP not HTTPS
```

#### 🚨 Backend Protocol Mismatch

**Problem**: HTTP 500 errors after routing works.

**Cause**: Apache container serves HTTP internally, not HTTPS.

**Fix**: Use `http://` in service URL:
```yaml
servers:
  - url: "http://nextcloud-aio-apache:11000"  # NOT https://
```

**Test**: Direct connection should work:
```bash
curl -I http://localhost:11000  # Should return HTTP 302
```

#### 🚨 YAML Syntax Errors

**Problem**: Traefik won't start, keeps restarting.

**Common Errors**:
```yaml
# WRONG - duplicate keys
entryPoints:
  traefik:
    address: ":8090"
entryPoints:  # <-- Duplicate key
  web:
    address: ":80"

# RIGHT - single section
entryPoints:
  traefik:
    address: ":8090" 
  web:
    address: ":80"
```

**Debug**: Check Traefik logs:
```bash
docker logs traefik | grep -i "yaml\|error"
```

#### Quick Diagnostic Commands

**Full health check**:
```bash
# 1. All containers running?
docker ps --filter "name=nextcloud" | grep -v Exited

# 2. Traefik API accessible?
curl -s http://localhost:8090/api/http/routers | grep nextcloud

# 3. Apache responding?
curl -I http://localhost:11000

# 4. Full chain working?
curl -I https://drive.cliff.li  # Should return 302

# 5. Any errors?
docker logs traefik --since 5m | grep -i error
```

#### Working State Checklist

When everything works correctly:

✅ **Ports**:
  - `8090`: Traefik API (returns JSON)
  - `8080`: AIO master (returns HTML)  
  - `11000`: Apache container (returns 302)

✅ **Networks**: 
```bash
docker inspect nextcloud-aio-apache | grep -A 20 "Networks"
# Shows: nextcloud-aio (internal) + traefik (proxy)
```

✅ **Routing**:
```bash
curl -s http://localhost:8090/api/http/routers | grep nextcloud
# Shows: nextcloud@file route with correct configuration
```

✅ **Final Response**:
```bash
curl -I https://drive.cliff.li
# HTTP/2 302
# location: https://drive.cliff.li/login
```

#### Legacy Issues (Less Common)

#### Domain Validation Issues
If you see domain validation errors:
1. Verify DNS points to your VPS
2. Check domain accessibility from internet
3. Set `SKIP_DOMAIN_VALIDATION=true` temporarily

#### SSL/Certificate Issues  
- AIO handles internal SSL
- Traefik handles external SSL with Let's Encrypt
- Never configure SSL in master container

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

### Lessons Learned

This deployment taught us several important lessons about Nextcloud AIO + Traefik integration:

#### Why This Setup is Complex

1. **AIO's Design**: Nextcloud AIO manages containers dynamically, preventing standard Docker label-based configuration
2. **Port Conflicts**: Both AIO and Traefik default to port 8080, creating hidden conflicts
3. **Network Isolation**: AIO creates its own network, requiring explicit bridging to Traefik
4. **Protocol Mismatch**: Internal containers use different protocols than external expectations

#### The "Correct" Approach

Based on community research and our experience:

1. **Use File Provider**: Static configuration files, not Docker labels
2. **Separate Admin/Service**: AIO admin stays on 8080, Nextcloud service uses 11000  
3. **Bridge Networks**: Use `APACHE_CONTAINER_ADDITIONAL_NETWORK` (note the exact spelling)
4. **HTTP Backend**: Internal connections use HTTP, Traefik handles HTTPS termination

#### Key Debugging Skills

1. **Check Port Bindings**: `docker port container-name` reveals conflicts
2. **Inspect Networks**: Container networking issues are common
3. **Read Traefik API**: `/api/http/routers` shows what Traefik actually sees
4. **Test Each Layer**: VPS → Tailscale → Traefik → Apache → Nextcloud

#### What Made This Hard

- **Multiple Failure Points**: 5+ different systems in the proxy chain  
- **Misleading Errors**: 502 errors could be network, config, or protocol issues
- **Hidden Port Conflicts**: No obvious indication that Traefik couldn't bind to 8080
- **Documentation Gaps**: Official examples don't cover all edge cases

#### Future Recommendations

1. **Always check port conflicts first** when mixing multiple services
2. **Use Traefik API for debugging** - it shows exactly what's configured
3. **Test direct connectivity** at each layer before debugging the full chain
4. **Keep admin interfaces separate** from proxied services
5. **File provider is more reliable** than labels for complex setups

### Resources

- [Nextcloud All-in-One GitHub](https://github.com/nextcloud/all-in-one)
- [Reverse Proxy Documentation](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md)  
- [Nextcloud Documentation](https://docs.nextcloud.com/)
- [Traefik File Provider Docs](https://doc.traefik.io/traefik/providers/file/)
- [Docker Network Troubleshooting](https://docs.docker.com/network/troubleshooting/)