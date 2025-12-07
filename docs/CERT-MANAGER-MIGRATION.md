# cert-manager Migration Summary

## Date
December 5-6, 2025

## Overview
Migrated from Traefik's built-in ACME certificate resolver to cert-manager for SSL certificate management.

## Why Migrate?

### The Problem
When Traefik was converted to a DaemonSet for high availability:
1. **Certificate conflicts**: Multiple Traefik instances racing to manage the same ACME account
2. **Storage issues**: ACME cert storage moved to NFS, causing lock contention
3. **HTTP redirect breaking renewals**: `redirect-entry-point: websecure` annotation redirected ALL HTTP traffic (including ACME HTTP-01 challenges) to HTTPS, breaking certificate renewals
4. **Certificate expiry**: Existing certificates expired, causing ServiceDown alerts
5. **404 errors on HTTPS**: Missing TLS configuration on websecure entrypoint

### The Solution
cert-manager provides:
- Centralized certificate management (no race conditions)
- Kubernetes-native Certificate resources
- Proper ACME challenge handling with path priority
- Better observability (kubectl get certificates, challenges, etc.)
- HA-compatible architecture

## Changes Made

### 1. Traefik Configuration
**File**: `cluster/manifests/traefik/traefik-config.yaml`

- **Added**: TLS configuration to websecure entrypoint
  ```yaml
  websecure:
    address: ":443"
    proxyProtocol:
      trustedIPs:
        - "100.121.249.71/32"
    http:
      tls: {}  # NEW: Required for HTTPS routing in Traefik v3
  ```

- **Removed**: Traefik ACME certificatesResolvers section
  ```yaml
  # certificatesResolvers:  # COMMENTED OUT
  #   letsencrypt:
  #     acme:
  #       email: cliff.li@cliff.li
  #       storage: /acme/acme.json
  ```

### 2. cert-manager Installation
**Files**: `cluster/manifests/cert-manager/`

- Created `letsencrypt-issuers.yaml` with:
  - ClusterIssuer for Let's Encrypt staging
  - ClusterIssuer for Let's Encrypt production
  - HTTP-01 challenge solver with Traefik
  - **Critical**: High priority annotation for challenge ingresses
    ```yaml
    ingressTemplate:
      metadata:
        annotations:
          traefik.ingress.kubernetes.io/router.priority: "100"
    ```

### 3. Ingress Annotations
**Changed in all ingress files**:

- **Removed**:
  ```yaml
  traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
  traefik.ingress.kubernetes.io/redirect-entry-point: websecure
  ```

- **Added**:
  ```yaml
  cert-manager.io/cluster-issuer: letsencrypt-production
  ```

**Affected files**:
- `cluster/applications/utilities/whoami/ingress.yaml`
- `cluster/applications/cloud/immich/ingress.yaml`
- `cluster/applications/cloud/nextcloud/ingress.yaml`
- `cluster/applications/location/owntracks/ingress.yaml`
- `cluster/applications/media-stack/ingress.yaml` (5 ingresses)
- `cluster/manifests/traefik/traefik-dashboard-ingress.yaml`

### 4. Monitoring Stack
**File**: `cluster/applications/monitoring/kube-prometheus-stack-values.yaml`

Updated ingress annotations for:
- Prometheus
- Alertmanager
- Grafana

### 5. Documentation Updates
**File**: `README.md`

- Updated architecture description to mention cert-manager
- Updated troubleshooting commands for cert-manager
- Updated storage layout documentation

## Certificate Status

### Successfully Issued (11/13)
- ✅ prometheus.cliff.li
- ✅ grafana.cliff.li
- ✅ alertmanager.cliff.li
- ✅ whoami.cliff.li
- ✅ prowlarr.cliff.li
- ✅ sonarr.cliff.li
- ✅ radarr.cliff.li
- ✅ qbittorrent.cliff.li
- ✅ drive.cliff.li (nextcloud)
- ✅ traefik.cliff.li
- ✅ owntracks.cliff.li

### Successfully Issued (13/13)
- ✅ prometheus.cliff.li
- ✅ grafana.cliff.li
- ✅ alertmanager.cliff.li
- ✅ whoami.cliff.li
- ✅ prowlarr.cliff.li
- ✅ sonarr.cliff.li
- ✅ radarr.cliff.li
- ✅ qbittorrent.cliff.li
- ✅ drive.cliff.li (nextcloud)
- ✅ traefik.cliff.li
- ✅ owntracks.cliff.li
- ✅ photos.cliff.li
- ✅ jellyfin.cliff.li

**Note**: All certificates were successfully issued after the initial rate-limiting period.

## Post-Migration Configuration

### HTTP to HTTPS Redirection
The `traefik.ingress.kubernetes.io/redirect-entry-point: websecure` annotation was removed during the migration because it interfered with the HTTP-01 challenge. To re-enable HTTP to HTTPS redirection, use the `https-redirect` middleware.

The `https-redirect` middleware is defined in `cluster/manifests/traefik/traefik-https-redirect-middleware.yaml`. To apply it to an ingress, add the following annotation:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: infrastructure-https-redirect@kubernetescrd
```

If other middlewares are already present, add it as a comma-separated list:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: infrastructure-https-redirect@kubernetescrd,other-middleware@kubernetescrd
```

This has been applied to the `immich` and `jellyfin` ingresses.

## Technical Details

### Path Priority Issue
Traefik doesn't automatically prioritize specific paths over `PathPrefix: /`. cert-manager's ACME challenge ingresses need explicit priority:

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.priority: "100"
```

Without this, requests to `/.well-known/acme-challenge/` would match the main ingress (`PathPrefix: /`) first, returning 404.

### TLS Configuration Required
In Traefik v3.0, the `websecure` entrypoint MUST have TLS explicitly enabled:

```yaml
websecure:
  http:
    tls: {}
```

Without this, Traefik accepts connections on port 443 but doesn't perform TLS termination, causing all HTTPS requests to return 404.

### HTTP Redirect Removal
The old `redirect-entry-point: websecure` annotation caused:
1. ALL HTTP traffic redirected to HTTPS
2. ACME HTTP-01 challenges redirected → 404
3. Certificate renewal failures

Solution: Remove the annotation. HTTP-to-HTTPS redirect can be implemented via middleware if needed.

## Operational Commands

### Check Certificate Status
```bash
# List all certificates
kubectl get certificates -A

# Detailed certificate info
kubectl describe certificate -n <namespace> <cert-name>

# Check ACME challenges
kubectl get challenges -A

# View cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

### Force Certificate Renewal
```bash
# Delete the certificate request to trigger renewal
kubectl delete certificaterequest -n <namespace> <cert-request-name>
```

### Manual Certificate Creation
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-tls
  namespace: example
spec:
  secretName: example-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - example.cliff.li
```

## Lessons Learned

1. **Always test with staging first**: Let's Encrypt staging has higher rate limits
2. **Priority matters**: Traefik path matching needs explicit priorities
3. **HTTP-01 needs HTTP**: Never redirect ALL HTTP traffic when using HTTP-01 challenges
4. **Traefik v3 TLS config**: websecure entrypoint needs `http.tls: {}` explicitly
5. **cert-manager > Traefik ACME for HA**: Built-in ACME doesn't work well with multiple instances

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Traefik v3 cert-manager Integration](https://doc.traefik.io/traefik/v3.3/user-guides/cert-manager/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [Traefik GitHub Issue #10702](https://github.com/traefik/traefik/issues/10702) - v3.0 cert-manager issues
