#!/usr/bin/env bash
# Immich Deployment Script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="cloud"

echo "🚀 Deploying Immich..."

# Step 1: Generate strong passwords if secrets file hasn't been customized
echo "📝 Step 1: Checking secrets..."
if grep -q "CHANGE_ME_STRONG_PASSWORD" "$SCRIPT_DIR/secrets.yaml"; then
    echo "⚠️  WARNING: Please update the passwords in immich/secrets.yaml before deploying!"
    echo "   Generate a strong password with: openssl rand -base64 32"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 2: Apply supporting resources (PostgreSQL, Redis, Storage)
echo "📦 Step 2: Applying supporting resources..."
kubectl apply -f "$SCRIPT_DIR/secrets.yaml"
kubectl apply -f "$SCRIPT_DIR/storage-pvs.yaml"
kubectl apply -f "$SCRIPT_DIR/storage-pvcs.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres.yaml"
kubectl apply -f "$SCRIPT_DIR/redis.yaml"
kubectl apply -f "$SCRIPT_DIR/middleware.yaml"

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=immich-postgres -n $NAMESPACE --timeout=300s

# Wait for Redis to be ready
echo "⏳ Waiting for Redis to be ready..."
kubectl wait --for=condition=ready pod -l app=immich-redis -n $NAMESPACE --timeout=120s

# Step 3: Add Helm repo and deploy Immich
echo "📦 Step 3: Deploying Immich via Helm..."
helm repo add immich https://immich-app.github.io/immich-charts 2>/dev/null || true
helm repo update

# Install or upgrade Immich
helm upgrade --install immich immich/immich \
    --namespace $NAMESPACE \
    --values "$SCRIPT_DIR/values.yaml" \
    --wait \
    --timeout 10m

# Step 4: Apply ingress
echo "🌐 Step 4: Applying ingress configuration..."
kubectl apply -f "$SCRIPT_DIR/ingress.yaml"

echo ""
echo "✅ Immich deployment complete!"
echo ""
echo "📍 Access Immich at: https://immich.cliff.li"
echo ""
echo "📝 Next steps:"
echo "   1. Configure DNS to point immich.cliff.li to your cluster"
echo "   2. Access the web interface and complete initial setup"
echo "   3. Download the Immich mobile app and configure it to connect to your server"
echo ""
echo "🔍 Check status with:"
echo "   kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=immich"
echo "   kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=immich-server -f"
