# Immich - Self-Hosted Photo and Video Management

Immich is a high-performance self-hosted photo and video management solution, similar to Google Photos.

> ⚠️ **Current state (checked 2026-08-21):** the Helm release is in `failed`
> status at revision 21 (chart `immich-0.10.3`, app `v2.0.0`, last touched
> 2025-12-09) even though `immich-server`, `immich-machine-learning` and
> `immich-redis` are all running 1/1. A failed release blocks nothing today but
> will complicate the next `helm upgrade`. Inspect with
> `helm status immich -n cloud` and `helm history immich -n cloud` before
> upgrading; a `helm rollback` to the last good revision may be needed first.

## Architecture

- **Database**: PostgreSQL 16 with pgvecto-rs extension (for ML features)
- **Cache**: Redis 7.2
- **Storage**: a single NFS volume on the mergerFS pool — see below
- **Deployment**: Helm chart from official Immich repository

## Storage Setup

`immich-server` mounts **one** volume: PVC `immich-library` at `/data`.

```
PV immich-library  →  192.168.1.94:/media/immich/library  →  /media/data/immich/library
```

Everything Immich writes lives under that one directory on the mergerFS pool
(sizes measured 2026-09-21):

| Path under `/media/data/immich/library/` | Size | Contents |
|---|---|---|
| `library/` | 250G | originals, `<user>/<year>/<date>/` |
| `encoded-video/` | 36G | transcodes, plus some live/motion-photo originals |
| `thumbs/` | 14G | generated thumbnails |
| `upload/` | 4.9G | staging, plus some originals |
| `backups/` | 3.5G | Immich's own database dumps |
| `profile/` | 8K | profile pictures |

Note the doubled segment: because the PV is mounted at `/data` and Immich
creates its own `library/` inside, originals are at
`/media/data/immich/library/library/<user>/...`. `asset.originalPath` in the
database is the container path (`/data/library/...`); strip `/data` and prepend
`/media/data/immich/library` to get the host path.

> ⚠️ **The SSD split described in earlier revisions of this file is not in
> effect.** It claimed thumbnails, encoded video and profile pictures lived on
> `/srv/app-storage/immich/`. They do not, and never have on this host:
>
> - `values.yaml` sets only `immich.persistence.library.existingClaim`, so the
>   chart mounts nothing else — `immich-server` has exactly one data mount.
> - `/srv/app-storage/immich/` **does not exist**; `/srv/app-storage/` has no
>   `immich` directory at all.
> - `kustomization.yaml` does still create PVCs `immich-thumbs` (20Gi),
>   `immich-encoded-video` (30Gi), `immich-profile` (1Gi) and `immich-config`
>   (10Gi). All four are `Bound` and all four are **unused** — a static NFS PV
>   binds without the server path having to exist, so `Bound` proves nothing
>   here.
>
> Adopting the split would mean creating those directories on the SSD, wiring
> the claims into `values.yaml`, and **moving the existing 50G of thumbs and
> encoded video** — not just pointing at empty mounts, which would orphan what
> is already there. Until then, treat the four extra PVCs as dead weight.

## Pre-Deployment Steps

1. **Generate strong passwords**:
   ```bash
   openssl rand -base64 32
   ```

2. **Update secrets**:
   Edit `secrets.yaml` and replace `CHANGE_ME_STRONG_PASSWORD` with your generated passwords.

## Deployment

Immich is split across two tools: **Kustomize** owns the supporting resources
(secrets, PVs/PVCs, PostgreSQL, Redis, ingress, middlewares) and **Helm** owns
the Immich application itself.

1. **Apply the supporting resources with Kustomize** — this covers everything in
   `kustomization.yaml`, including the ingress and middlewares:
   ```bash
   kubectl apply -k cluster/applications/cloud/immich/
   ```

   Or individually:
   ```bash
   kubectl apply -f cluster/applications/cloud/immich/secrets.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-pvs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-pvcs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-cache-pvs.yaml
   kubectl apply -f cluster/applications/cloud/immich/storage-cache-pvcs.yaml
   kubectl apply -f cluster/applications/cloud/immich/postgres.yaml
   kubectl apply -f cluster/applications/cloud/immich/redis.yaml
   kubectl apply -f cluster/applications/cloud/immich/middleware.yaml
   kubectl apply -f cluster/applications/cloud/immich/ingress.yaml
   ```

2. **Deploy Immich via Helm**:
   ```bash
   helm repo add immich https://immich-app.github.io/immich-charts
   helm repo update

   helm upgrade --install immich immich/immich \
       --namespace cloud \
       --values cluster/applications/cloud/immich/values.yaml \
       --wait
   ```

## Access

- **URL**: https://photos.cliff.li
- **DNS**: Ensure `photos.cliff.li` points to your cluster's ingress IP

## Post-Deployment

1. Access the web interface at https://photos.cliff.li
2. Complete the initial setup wizard
3. Create your admin account
4. Download the Immich mobile app (iOS/Android)
5. Configure the app to connect to `https://photos.cliff.li`

## Machine Learning

Machine learning is **enabled** (`machine-learning.enabled: true` in
`values.yaml`); the `immich-machine-learning` deployment runs in the `cloud`
namespace. To disable it and reclaim the resources, set `enabled: false` and
upgrade the release:

```bash
helm upgrade immich immich/immich \
    --namespace cloud \
    --values cluster/applications/cloud/immich/values.yaml
```

## Monitoring

Check deployment status:
```bash
# View all Immich pods
kubectl get pods -n cloud -l app.kubernetes.io/instance=immich

# View logs
kubectl logs -n cloud deploy/immich-server -f

# Check PostgreSQL
kubectl logs -n cloud immich-postgres-0

# Check Redis
kubectl logs -n cloud deploy/immich-redis
```

## Maintenance

### Backup

Important data to backup:
- PostgreSQL database: `immich-postgres-0` PVC (local-path storage, reclaim
  policy `Delete` — deleting the PVC destroys it permanently)
- Everything else: `/media/data/immich/library` (one tree, see Storage Setup).
  The irreplaceable parts are `library/` and `upload/`; `thumbs/` and
  `encoded-video/` are regenerable but cost hours of CPU to rebuild.

### Upgrade

Update to the latest Immich version:
```bash
helm repo update
helm upgrade immich immich/immich \
    --namespace cloud \
    --values cluster/applications/cloud/immich/values.yaml
```

## Troubleshooting

### Pod not starting
```bash
kubectl describe pod -n cloud -l app.kubernetes.io/instance=immich
kubectl logs -n cloud deploy/immich-server
```

### Database connection issues
```bash
# Check PostgreSQL is running
kubectl get pods -n cloud -l app=immich-postgres

# Check PostgreSQL logs
kubectl logs -n cloud immich-postgres-0

# Test database connectivity
kubectl exec -n cloud immich-postgres-0 -- psql -U immich -d immich -c "SELECT version();"
```

### Storage issues
```bash
# Check PVCs (immich-library is the only one the server mounts; thumbs,
# encoded-video, profile and config are Bound but unused — see Storage Setup)
kubectl get pvc -n cloud | grep immich

# Check PVs
kubectl get pv | grep immich

# Verify mounts inside container
kubectl exec -n cloud deploy/immich-server -- df -h | grep /data

# Check NFS exports
showmount -e 192.168.1.94
```

### Umlauts stored as Private-Use-Area characters (fixed 2026-09-25)

Every asset whose filename contained a German umlaut had its path corrupted in
the database: the Latin-1 byte was mapped into the Unicode Private Use Area by
adding `0xEF00`, so `ö` (`U+00F6`) was stored as `U+EFF6`.

| Stored | Should be | Char |
|---|---|---|
| `U+EFE4` | `U+00E4` | ä |
| `U+EFF6` | `U+00F6` | ö |
| `U+EFFC` | `U+00FC` | ü |

Those three were the only ones present, across 22 assets. It was **every**
non-ASCII path in the library — there were no correctly-encoded ones — so
assume any future umlaut import is affected until proven otherwise. The origin
is unknown; it predates this repo's records, and nothing here reproduces it.

The files themselves were never damaged: all 22 existed on disk with correct
UTF-8 names and SHA-1s matching `asset.checksum`. Only the pointer was wrong,
so thumbnails (already generated) still displayed while anything reading the
original — full-resolution view, download, re-processing — failed.

Immich has no supported repair for this. The
[System Integrity](https://docs.immich.app/administration/system-integrity/)
page only *reports* missing files, and the documented remedy is delete and
re-upload, which would lose album membership, faces and metadata.

`scripts/fix-immich-pua-paths.sql` corrects the rows instead. It runs in a
transaction with a `DO` block that raises unless every PUA character is gone,
so a partial fix cannot commit:

```bash
kubectl exec -i -n cloud immich-postgres-0 -- \
    psql -U immich -d immich -v ON_ERROR_STOP=1 < scripts/fix-immich-pua-paths.sql
```

Detect a recurrence with:

```bash
kubectl exec -n cloud immich-postgres-0 -- psql -U immich -d immich -t -A -c \
  "SELECT count(*) FROM asset WHERE \"originalPath\" ~ U&'[\\E000-\\F8FF]';"
```

> To confirm a hit by hand, compare `octet_length` with `length` — a path with
> more bytes than characters holds a multi-byte character, which is how this
> was first spotted.

**Reversing it.** Two levels, both on the storage node:

| Artifact | What it is |
|---|---|
| `/media/data/backups/immich-pre-pua-fix-20260925-080536.sql` | full `pg_dump`, 694 MB, completion marker verified, 43,999 asset rows |
| `/media/data/backups/undo-immich-pua-fix-20260925.sql` | 22 targeted `UPDATE`s restoring the exact prior values |

Prefer the undo script — it is instant and touches only those rows. Its values
are hex-encoded UTF-8, so the file is pure ASCII and cannot be mangled in
transit the way the original data was. It was tested by running it against the
repaired database inside a rolled-back transaction: it restored all 22 rows,
then rolled back cleanly.

> ⚠️ Take a fresh dump before running any of this. `kubectl exec` silently
> truncates large stdout and still exits 0
> ([kubernetes#124571](https://github.com/kubernetes/kubernetes/issues/124571)),
> so always confirm the dump ends with `PostgreSQL database dump complete` and
> retry if not — `scripts/backup-databases.sh` does this, and the one-off dump
> above was verified the same way.

## Resources

- [Immich Documentation](https://immich.app/docs)
- [Immich GitHub](https://github.com/immich-app/immich)
- [Immich Helm Charts](https://github.com/immich-app/immich-charts)
