# Services

This directory contains Docker Compose configurations for various services that run on the home PC.

Each subdirectory should contain:
- `docker-compose.yml` - Service configuration
- Any additional configuration files needed

## Adding a new service

1. Create a new directory for your service
2. Add a `docker-compose.yml` file with Traefik labels for routing
3. Make sure the service uses the `traefik` network
4. Run the home-pc setup script to deploy all services

## Example service configuration

See `example-app/` for a basic nginx service with Traefik integration.