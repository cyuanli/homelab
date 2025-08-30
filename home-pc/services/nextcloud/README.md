# Nextcloud Service

Self-hosted Nextcloud instance with PostgreSQL and Redis, deployed behind Traefik with automatic HTTPS.

## Quick Start

```bash
cd ~/homelab/home-pc/services/nextcloud
docker-compose up -d
```

Access at: https://drive.cliff.li

**Default credentials:**
- Username: `admin`
- Password: Set in your `.env` file

⚠️ **Change the admin password after first login**

## Architecture

- **Nextcloud**: Main application (Apache variant)
- **PostgreSQL 16**: Database backend with health checks
- **Redis 7**: Caching and session storage with persistence
- **Traefik v3**: Reverse proxy with SSL termination and security headers

## Configuration

### Environment Variables

Key settings are stored in `.env` file:

```bash
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<your-secure-password>
POSTGRES_PASSWORD=<your-db-password>
REDIS_PASSWORD=<your-redis-password>
```

⚠️ **Never commit passwords to git** - they're stored in `.env` file which is ignored.

### Custom Configuration

Advanced settings in `custom-config.php`:
- **Trusted proxies**: Configured for Docker network ranges
- **Maintenance window**: Set to 3 AM for background jobs
- **Phone region**: Default region for phone number validation
- **CLI URL**: Proper CLI access configuration

### Data Storage

- **User files**: `/media/data/nextcloud` (host mount)
- **App data**: `nextcloud_data` volume  
- **Database**: `db_data` volume
- **Redis cache**: `redis_data` volume (persisted)

### Traefik Integration

Direct routing with standard Docker labels:
- **Automatic HTTPS** via Let's Encrypt
- **Security headers**: HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- **CalDAV/CardDAV redirects**: `.well-known` URLs properly redirected for client sync
- **Health checks**: All containers monitored with health checks
- **Proper dependencies**: Containers start in correct order
- **Domain**: `drive.cliff.li`

## Management

### Updates

```bash
docker-compose pull
docker-compose up -d
```

### Logs

```bash
docker-compose logs -f nextcloud
docker-compose logs -f db
```

### Backup Database

```bash
docker-compose exec db pg_dump -U nextcloud nextcloud > backup.sql
```

### Restore Database

```bash
cat backup.sql | docker-compose exec -T db psql -U nextcloud nextcloud
```

## Security Notes

- Change default passwords before production use
- Database and Redis are isolated on internal network
- External access only through Traefik with HTTPS
- User data stored on host filesystem for easy backup

## Troubleshooting

### Check Container Status
```bash
docker-compose ps
```

### Database Connection Issues
```bash
docker-compose exec nextcloud php occ db:check-status
```

### Clear Redis Cache
```bash
docker-compose exec redis redis-cli -a ${REDIS_PASSWORD} flushall
```

### Permission Issues
```bash
sudo chown -R www-data:www-data /media/data/nextcloud
```

## Adding Apps

Use the web interface or command line:
```bash
docker-compose exec nextcloud php occ app:install calendar
```