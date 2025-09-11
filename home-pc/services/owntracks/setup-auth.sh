#!/bin/bash

# OwnTracks HTTP Authentication Setup Script
# Run this to generate HTTP Basic Auth credentials

set -e

echo "Setting up OwnTracks HTTP Basic Authentication..."

# Check if htpasswd is available
if ! command -v htpasswd &> /dev/null; then
    echo "htpasswd not found. Installing apache2-utils..."
    sudo apt-get update && sudo apt-get install -y apache2-utils
fi

echo "Enter username for OwnTracks:"
read -r USERNAME

echo "Enter password for OwnTracks:"
read -rs PASSWORD

# Generate htpasswd entry
HTPASSWD_ENTRY=$(htpasswd -nb "$USERNAME" "$PASSWORD")

# Escape the $ characters for docker-compose
ESCAPED_ENTRY=$(echo "$HTPASSWD_ENTRY" | sed 's/\$/\$\$/g')

echo ""
echo "Generated authentication entry:"
echo "$HTPASSWD_ENTRY"
echo ""
echo "Add this to your .env file (copy from .env.template):"
echo "OWNTRACKS_AUTH_USERS=$ESCAPED_ENTRY"
echo ""
echo "Then restart the service: docker-compose up -d"
echo ""
echo "Configure your OwnTracks mobile apps with:"
echo "Mode: HTTP"
echo "URL: https://owntracks.\${DOMAIN}/pub"  
echo "Username: $USERNAME"
echo "Password: [the password you entered]"
echo ""
echo "Web interface will be available at:"
echo "https://owntracks.\${DOMAIN}/"
echo "(Use the same username/password)"