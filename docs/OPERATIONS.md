# Operations Guide

## Daily Commands

```bash
./scripts/homelab.sh status      # Cluster health
kubectl get pods -A              # All pods
kubectl logs -n <ns> deployment/<svc> --tail=50  # Service logs
```

## Service Management

```bash
# Restart a service
kubectl rollout restart deployment/<service> -n <namespace>

# Scale down (stop)
kubectl scale deployment/<service> -n <namespace> --replicas=0

# Scale up
kubectl scale deployment/<service> -n <namespace> --replicas=1

# Redeploy
kubectl apply -k cluster/applications/<category>/<service>/
```

## Node Management

```bash
# Add new node
./scripts/manage-nodes.sh add <hostname> --role server  # or agent

# Add to ansible/inventory.yml, then run Ansible playbooks including k3s.yml (see INSTALLATION.md)

# Drain node for maintenance
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Return to service
kubectl uncordon <node>
```

## Backups (Borgmatic)

Automated backups using borgmatic with systemd timer (daily at 3:00 AM).

### Installation

```bash
sudo apt install borgmatic
sudo mkdir -p /etc/borgmatic

# The repo's tracked config is config/borgmatic/config.yaml
sudo cp config/borgmatic/config.yaml /etc/borgmatic/config.yaml
# Edit with your backup repositories and passphrase

# Enable timer
sudo cp config/borgmatic/systemd/*.service /etc/systemd/system/
sudo cp config/borgmatic/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now borgmatic.timer
```

The hooks run `scripts/backup-notify.sh` straight from the repo path. Nothing
is copied to `/etc/borgmatic/hooks/`.

`borgmatic.service` also carries an `ExecStopPost=` calling the same script with
`$SERVICE_RESULT`. borgmatic's own `on_error` hook cannot run if the process is
killed, so without it an OOM or timeout leaves `borgmatic_last_run_status` at 1.

The passphrase lives in `config/borgmatic/.borg-passphrase` /
`.borg-passphrase-env` — both gitignored.

### Commands

```bash
# Check borgmatic status
sudo systemctl status borgmatic.timer
journalctl -u borgmatic.service -n 50

# Manual backup
sudo systemctl start borgmatic.service

# View backup metrics
cat /var/lib/node_exporter/textfile_collector/borgmatic.prom
```

Alerts via Prometheus/Alertmanager. See `cluster/applications/monitoring/`.

### Database dumps

`source_directories` only covers file trees. The Nextcloud and Immich databases
live in `local-path` PVCs and are captured by `scripts/backup-databases.sh`,
which runs from borgmatic's `before_backup` hook (after Nextcloud maintenance
mode is enabled, so its dump is taken while the app is quiesced).

It writes `/media/data/db-dumps/{immich,nextcloud}.sql` — one current dump per
database, mode `0600` in a `0700` directory. Versioning is borg's job: the
retention policy above gives 7 daily / 4 weekly / 6 monthly copies. Dumps are
left uncompressed on purpose, because borg dedupes an uncompressed dump against
the previous night's far better than a gzip stream, where one changed row
perturbs the whole file.

Dumps are written atomically (`.part` → `mv`) and only promoted if pg_dump's
completion marker is present, since `pg_dump` exits 0 on a connection dropped
mid-stream.

> ⚠️ **`kubectl exec` silently truncates large stdout and still exits 0**
> ([kubernetes#124571](https://github.com/kubernetes/kubernetes/issues/124571)).
> Measured on the 693 MB immich dump at roughly 3 attempts in 10. The dump is
> retried up to 3 times against the completion marker, which is the only
> reliable detector. Do not drop the retry loop or the marker check.

> ⚠️ **A failed dump does not fail the backup.** The script always exits 0 so
> that one unreachable database cannot cost you that night's file backups. It
> keeps the previous dump and reports the failure as metrics instead — so
> `BorgmaticBackupFailed` will **not** fire, and borgmatic reports success while
> archiving a stale database. The `DatabaseDumpFailed` / `DatabaseDumpStale` /
> `DatabaseDumpSuspiciouslySmall` alerts in
> `prometheus-rules-system-monitoring.yaml` are the only signal. Do not remove
> them without replacing that signal.

```bash
# Verify dumps are current
ls -la /media/data/db-dumps/
cat /var/lib/node_exporter/textfile_collector/db-dumps.prom

# Run the dump by hand
sudo ./scripts/backup-databases.sh
```

Under `sudo` the invoking user's `~/.kube/config` is out of reach, so the script
falls back to `/etc/rancher/k3s/k3s.yaml` — the same value `borgmatic.service`
sets. It therefore only runs on a server node. If the API is unreachable it says
so explicitly rather than reporting each database as individually missing.

Adding a database means appending one `name|namespace|selector|user|dbname` line
to the `DATABASES` array in the script.

### Restoring a database

Restore into a **fresh, empty** database. Immich's docs are explicit that a
restore requires an instance that has never run; if it has, the database must be
cleared first, otherwise the restore hits constraint violations.

```bash
# 1. Get the dump out of borg
borgmatic list                              # find the archive
borgmatic extract --archive <archive> --path media/data/db-dumps/immich.sql

# 2. Stop the consumers so nothing writes during the restore
kubectl scale -n cloud deployment/immich-server deployment/immich-machine-learning --replicas=0

# 3. Restore
kubectl exec -i -n cloud immich-postgres-0 -- \
  psql --username=immich --dbname=immich --single-transaction --set ON_ERROR_STOP=on \
  < immich.sql

# 4. Bring it back
kubectl scale -n cloud deployment/immich-server --replicas=1
kubectl scale -n cloud deployment/immich-machine-learning --replicas=1
```

> ⚠️ **Immich `search_path` caveat.** If the restore fails on the vector
> extension, Immich's documented workaround is to rewrite the search_path line
> as the dump is piped in:
>
> ```bash
> sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" immich.sql | kubectl exec -i ...
> ```
>
> Source: [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore/).
> Note this cluster runs `tensorchord/pgvecto-rs:pg16-v0.2.0`; upstream Immich
> has since moved to VectorChord and dropped pgvecto-rs support as of its
> database image 3.0, so a restore onto a newer image is a migration, not a
> restore. Restore onto the same image version.

For Nextcloud, substitute `postgres-0`, user/db `nextcloud`, and scale
`deployment/nextcloud` instead — or leave it in maintenance mode throughout.

**Neither restore path has been exercised end to end.** Test it before you need
it: a backup you have never restored is a hypothesis, not a backup.

## Scheduled Tasks (Systemd Timers)

| Timer | Schedule | Node Group | Purpose |
|-------|----------|------------|---------|
| `snapraid-runner` | Daily 2 AM | storage | SnapRAID sync/scrub |
| `disk-monitor` | Every 5 min | storage | Disk health checks |
| `auto-remediate` | Every 15 min | monitoring | Restart services on alerts |
| `claude-investigate` | Every 15 min | cyl-homelab | Claude Code investigates new alerts, reports to Discord |
| `borgmatic` | Daily 3 AM | backup | Backups |

```bash
systemctl list-timers                    # All timers
journalctl -u <service>.service -n 50   # Timer logs
sudo systemctl start <service>.service  # Manual trigger
```

### Installing Timers

Timers are deployed via Ansible:

```bash
cd ansible
ansible-playbook playbooks/systemd-timers.yml --ask-become-pass
```

This deploys disk-monitor + snapraid-runner to storage nodes, auto-remediate to monitoring nodes,
and claude-investigate to cyl-homelab.

### Claude alert investigator

`scripts/claude-investigate.sh` runs headless Claude Code on every firing, unsilenced alert it
hasn't looked at in the last 6h (per Alertmanager fingerprint; `Watchdog`/`InfoInhibitor` skipped)
and posts the report to the alerts Discord channel, failures included. All new alerts in one tick
share one run. If Alertmanager is unreachable, that itself gets investigated.

Phase 1 is **read-only**, enforced in layers:

- `--setting-sources user` (in the script): the repo's `.claude/settings.local.json` is NOT
  loaded. It pre-approves `kubectl delete/apply/exec`, `bash`, `curl` etc.
- `config/claude-investigate/settings.json`: allowlist (kubectl, journalctl, `systemctl status`, git log/diff, reads inside
  the repo), with `dontAsk` + `--permission-prompts none` so anything else is denied, never asked.
- `guard.sh` (PreToolUse hook): rejects kubectl verbs other than get/describe/logs/top/events/…,
  anything mentioning secrets/tokens/passwords/`.env.local`, redirection, `$(…)`, shells, `rm`,
  `curl`, `ssh`, `sudo`, write-y `git`/`systemctl`. Test it by piping
  `{"tool_name":"Bash","tool_input":{"command":"…"}}` into it; exit 2 = blocked.
- `prompt.md`: appended system prompt, fixes the report format.

Allow rules match on command prefix, so `kubectl -n ai get` does NOT match `Bash(kubectl get:*)`.
That's why `settings.json` allows all of `kubectl` and `guard.sh` checks the verb.

State, run transcripts and the cached webhook URL live in `~/.local/state/claude-investigate`.
The webhook comes from the `alertmanager-discord-webhook` Secret (cached for when the API server is
down) or `DISCORD_WEBHOOK_URL`. Each Discord footer has `claude -r <session>` to continue the
investigation interactively from `~/homelab`.

```bash
scripts/claude-investigate.sh --dry-run          # what would be investigated
scripts/claude-investigate.sh --force            # ignore the 6h cooldown
# test end to end against silenced alerts, without touching the real cooldown
STATE_DIR=/tmp/ci AM_PATH="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=true&inhibited=true" \
  scripts/claude-investigate.sh --force
```

The playbook also adds `cyl` to `systemd-journal`; without it `journalctl` only sees the user's own
logs and host-level alerts (borgmatic, k3s, snapraid) can't be investigated.

Runs use the Claude subscription logged in for `cyl` on cyl-homelab (model/effort from
`~/.claude/settings.json`), not API credits, so they share usage limits with interactive sessions
and Hermes. Keep extra usage off. If the login expires (`claude auth status`, `loginExpiresAt`),
runs fail and post a red Discord message; fix with `claude auth login`.

Troubleshooting: `journalctl -u claude-investigate.service`; per run,
`runs/<id>.json` (`.permission_denials` lists what was blocked) and `runs/<id>.stderr`, pruned
after 30 days. If the Discord post itself fails, the unit fails and nothing is posted.

Before allowing fixes (phase 2): widen `settings.json` and `guard.sh` per fix type, and narrow
`/etc/sudoers.d/homelab-cyl` first. `user-permissions.yml` grants passwordless `systemctl`,
`chown`, `chmod` and `mount`, so any gap in the guard is root.

## Monitoring

```bash
# Prometheus metrics
cat /var/lib/node_exporter/textfile_collector/*.prom

# Grafana: https://grafana.cliff.li
# Prometheus: https://prometheus.cliff.li
# Alertmanager: https://alertmanager.cliff.li
```

### Textfile collector (script-exported metrics)

Every metric produced by a script — `disk_monitor_*`, `nfs_export_*`,
`snapraid_*`, `borgmatic_*`, `homelab_db_dump_*` — reaches Prometheus through
node_exporter's textfile collector, which reads `*.prom` files from
`/var/lib/node_exporter/textfile_collector/`.

> ⚠️ **A file in that directory is not the same as a metric in Prometheus.**
> The collector is enabled by default but reads nothing unless
> `--collector.textfile.directory` is set *and* the host directory is mounted
> into the DaemonSet. Neither was configured until 2026-08-22, so for as long as
> this repo has existed none of those metrics existed in Prometheus, and every
> alert built on them evaluated against no data. An alert rule matching no
> series does not fire and does not report an error — it is silent. Drive
> failure, SnapRAID, NFS export and backup alerting were all inert.
>
> The fix lives in the `prometheus-node-exporter.extraArgs` /
> `.extraHostVolumeMounts` block of `kube-prometheus-stack-values.yaml`.

Always confirm end to end rather than trusting the `.prom` file:

```bash
# 1. Does the collector see the files? (one series per .prom)
kubectl -n monitoring exec ds/kube-prometheus-stack-prometheus-node-exporter \
  -- wget -qO- localhost:9100/metrics | grep node_textfile_mtime_seconds

# 2. Did it parse cleanly? (must be 0 - a malformed file drops the WHOLE file)
kubectl -n monitoring exec ds/kube-prometheus-stack-prometheus-node-exporter \
  -- wget -qO- localhost:9100/metrics | grep node_textfile_scrape_error

# 3. Has Prometheus actually got the series?
curl -s --get "http://$(kubectl get svc -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.clusterIP}'):9090/api/v1/query" \
  --data-urlencode 'query=homelab_db_dump_success'
```

Two gotchas when writing a new exporter script:

- All samples of one metric family must be **contiguous** in the file. Interleaving
  families makes the parser reject the entire file — see the grouped `*_LINES`
  assembly in `scripts/backup-databases.sh`.
- Nothing prunes this directory. A `.prom` file left behind by a deleted script
  keeps exporting its final values forever, and they look current. Delete the
  file when you retire the script.

### SMART metrics (smartctl-exporter)

A privileged DaemonSet on all nodes, separate from the textfile collector above
and from `monitor-storage.sh`. It exports raw SMART attributes, not the
`smartctl -H` verdict.

```bash
helm upgrade --install smartctl-exporter prometheus-community/prometheus-smartctl-exporter \
  --version 0.17.1 -n monitoring \
  -f cluster/applications/monitoring/smartctl-exporter-values.yaml
```

> ⚠️ **`smartctl -H` does not detect a dying drive.** `Current_Pending_Sector`
> is an `Old_age` attribute with threshold `000`, so `-H` reports `PASSED` at
> any count. The retired WD50NDZW read `PASSED` at 88 pending sectors.
> `DiskPendingSectors` alerts on the raw value instead.

Relabeling maps `instance` and `node` to the node name so these series join
against node_exporter. The chart's own `prometheusRules` are NVMe-only and are
disabled. The real alerts live in `prometheus-rules-system-monitoring.yaml`.

Reallocated-sector and CRC alerts fire on `increase()` over 24h and 1h, not on
absolute value, because `sde` sits at 1 reallocated sector and `sdb` at 1 CRC
error. Both are stable and benign. Growth is not.

Temperature alerts join against `smartctl_device_rotation_rate > 0` to exclude
SSDs, which idle hotter by design.

### Monitoring Setup (One-time)

**Disk health monitoring** (for SnapRAID storage nodes):

No config file: the script reads the disks from `/etc/snapraid.conf`.

The check itself runs from `disk-monitor.timer` (every 5 minutes), deployed by
`ansible-playbook playbooks/systemd-timers.yml`. It is **not** a cron job.

```bash
./scripts/monitor-storage.sh status     # manual read
systemctl status disk-monitor.timer
journalctl -u disk-monitor.service -n 20
```

Beyond drive SMART/mount state it also validates the server-side NFS export
layer — see [Storage](STORAGE.md) → "Storage durability → Layer 4".

**Backup monitoring**: see the Backups (Borgmatic) section above.

## Certificate Management

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>

# Force renewal
kubectl delete certificaterequest -n <namespace> <request-name>
```

## VPS Proxy

```bash
# On VPS
sudo systemctl status nginx tailscaled
sudo tail -f /var/log/nginx/stream_error.log

# Test connectivity
curl -I http://100.x.x.x  # Homelab Tailscale IP
```

## Finding files stored in both Nextcloud and Immich

`scripts/find-duplicate-files.py` reports content that exists in both services,
matched by SHA-1 rather than by filename — the same photo is usually
`uploads/Camera/20250508_125034.jpg` in Nextcloud and
`library/admin/2025/2025-05-08/20250508_125034.jpg` in Immich, and Immich
renames plenty of others outright.

```bash
# Run on the storage node, with a working kubeconfig
./scripts/find-duplicate-files.py -o /media/data/backups/nc-immich-dupes.json
```

Read-only — SELECTs plus `sha1sum`, and the output file. Takes a few minutes.

### How it avoids hashing 941 GB

Both services already store a SHA-1 of every file, so most of the work is a
join, not a disk walk:

| Source | Column | Coverage |
|---|---|---|
| Immich | `asset.checksum` (bytea) | complete, all 44k assets |
| Nextcloud | `oc_filecache.checksum` (`SHA1:<hex>`) | ~27% of files |

The rest is narrowed by file size before anything is read: a file can only be a
duplicate if some Immich asset has exactly the same byte count. That takes
241k Nextcloud files down to ~10k candidates, of which ~8k need hashing (~72
GiB). `--no-size-filter` skips the narrowing and hashes everything, and
`--rehash` ignores Nextcloud's stored checksums.

Immich's library is world-readable on the host and is read directly.
Nextcloud's data directory is `0750 www-data`, so its files are hashed through
`kubectl exec` into the **Nextcloud application pod** (`app=nextcloud`) — not
its database pod. No sudo needed either way.

Both checksum columns were verified against `sha1sum` on the real files before
this script was trusted, and sampled matches were re-verified on both sides
afterwards.

> A candidate hashed in the pod proves it exists. One whose SHA-1 came from
> `oc_filecache` does not — a stale row can carry a checksum for a file deleted
> outside Nextcloud. The script therefore checks every candidate for existence
> before matching (`drop_missing`), so a phantom never reaches the report. This
> is rare (one entry in a 3,017-file manifest) but a phantom is
> indistinguishable from a real duplicate once it is in the output.

### Paths

The script maps container paths back to the host:

- Immich `originalPath` `/data/X` → `/media/data/immich/library/X`. Note the
  doubled segment: originals live at `.../library/library/...`, because the PV
  `/media/immich/library` is mounted at `/data` and Immich puts its own
  `library/`, `upload/`, `encoded-video/`, `thumbs/` and `profile/` inside it.
- Nextcloud `oc_filecache.path` `files/Y` for storage `home::<user>` →
  `/media/data/nextcloud/<user>/files/Y`.

> `asset.originalPath` is not always under `/data/library` — live-photo and
> motion-photo videos sit under `/data/upload` and `/data/encoded-video`. All
> three resolve into the same PV, so the single prefix swap above is enough.

### Output

```json
{
  "summary": { "matching_contents": 5596, "nextcloud_bytes_duplicated": 80872208886 },
  "matches": [
    {
      "sha1": "e522f01a...", "size": 900391172,
      "nextcloud": [{"user": "cyl", "path": "files/archive/...", "host_path": "/media/data/nextcloud/cyl/...", "sha1_source": "hashed"}],
      "immich": [{"asset_id": "f2077c1d-...", "owner": "cliff.li@cliff.li", "path": "/media/data/immich/library/library/..."}]
    }
  ],
  "nextcloud_unreadable": [{"user": "cyl", "path": "files/...", "size": 123}]
}
```

Both sides are lists: one content hash can have several copies in either
service. `sha1_source` records whether a Nextcloud hash came from the database
(`nextcloud-db`) or was computed (`hashed`).

> ⚠️ **The report identifies duplicates; it does not say which copy to delete.**
> Nextcloud and Immich each hold the only reference to their own copy, and
> deleting from either is a separate, destructive decision — back up first.

### `nextcloud_unreadable`

Candidates listed in `oc_filecache` but missing on disk; their duplicate status
is undecided, not negative. These are stale rows from files removed outside
Nextcloud.

## Reconciling the Nextcloud file cache

Only `cyl` ever had drift — `yingshao`, `admin` and `tessy` matched disk exactly
both before and after. Check any user with:

```bash
# Filesystem entries
kubectl exec -n cloud deploy/nextcloud -- \
    find /var/www/html/data/<user>/files -mindepth 1 | wc -l
# Cache rows for the same tree
kubectl exec -n cloud postgres-0 -- psql -U nextcloud -d nextcloud -t -A -c \
    "SELECT count(*) FROM oc_filecache f JOIN oc_storages s
       ON s.numeric_id=f.storage
     WHERE s.id='home::<user>' AND f.path LIKE 'files/%';"
```

> ⚠️ **Back up the database first.** `files:scan` rewrites `oc_filecache`, and
> dropping a row drops the fileid — taking its shares, tags and favourites with
> it. It never touches files on disk, but the metadata loss is irreversible.
> ```bash
> kubectl exec -n cloud postgres-0 -- pg_dump -U nextcloud -d nextcloud \
>     | gzip > /media/data/backups/nextcloud-pre-filescan-$(date +%Y%m%d-%H%M%S).sql.gz
> ```
> Verify it before proceeding: `gzip -t` the file, and check the row count in
> the dump matches the live table.

Then scan the affected user. Scope to one user rather than `--all`:

```bash
kubectl exec -n cloud deploy/nextcloud -- su -s /bin/sh www-data \
    -c 'php /var/www/html/occ files:scan cyl'
```

### What the 2026-09-21 run did

| | Before | After |
|---|---|---|
| `cyl` cache rows | 236,933 | 230,148 |
| `cyl` disk entries | 229,426 | 229,426 |
| Orphan rows | 7,507 | 731 |

The single pass removed 5,920 rows in 6m27s with 0 errors. Clearing the rest
took a second step, and a residue survives both — see below.

### Folders the scan skips

The scanner reuses a folder's cached mtime and skips re-reading its children
when it matches, so a single pass left 1,596 orphans in folders that had not
themselves changed. Rescanning each affected folder by `--path` forces the
re-read. Because deleting a folder row cascades to its subtree, this converges
over a few passes: compute the orphans' parents that still exist on disk,
rescan those, repeat. That took 1,596 → 731.

### Rows no scan can reach

The remaining **731 are parentless** — 692 have a `parent` fileid with no
matching row, and the other 39 descend from those:

```bash
kubectl exec -n cloud postgres-0 -- psql -U nextcloud -d nextcloud -c \
    "SELECT count(*) FROM oc_filecache f
     JOIN oc_storages s ON s.numeric_id=f.storage
     WHERE s.id='home::cyl' AND f.path LIKE 'files/%' AND f.parent <> -1
       AND NOT EXISTS (SELECT 1 FROM oc_filecache p WHERE p.fileid=f.parent);"
```

They arise when a folder row was deleted without its descendants. The scanner
enumerates children through their parent, so it can never visit them: a rescan
of the surviving ancestor reports `Removed 0` while the rows sit there. All 731
are under `cyl/files/archive/`, and many carry `?` where a non-UTF-8 filename
(GBK-encoded Chinese, from an old Windows backup) could not be decoded.

Clearing them needs a direct `DELETE` on `oc_filecache`, which is outside what
`occ` will do and was **not** run here.

### Files the scan deliberately ignores

Nine paths exist on disk with no cache row, and that is correct: six `.lnk`
files whose names are not valid UTF-8, and three `*.ocTransferId*.part` files,
which are abandoned chunked uploads that Nextcloud skips by design.

## Deleting duplicates from Nextcloud

Done once, for `cyl/files/uploads`, on 2026-09-25. Checks run first:

1. **Off-host backup verified, not assumed** — borgmatic's config covers
   `/media/data/nextcloud/*/files`; confirm the *archive* actually holds the
   tree: `borgmatic list --archive latest --find 'media/data/nextcloud/cyl/files/uploads'`
   (needs `config/borgmatic/.borg-passphrase-env`, readable by `cyl`).
2. **Re-run the finder the same day.** A report is a snapshot; the phone keeps
   uploading.
3. **Confirm the Immich original exists on disk for every file** in the
   manifest — not just that the database claims it.
4. **Check nothing depends on them**: `oc_share` (including ancestor folders),
   `oc_systemtag_object_mapping`, `oc_comments`, `oc_vcategory_to_object`.

Delete through `occ`, never `rm` — removing files under Nextcloud's feet
recreates the orphan-row problem above:

```bash
printf '%s\n' /cyl/files/uploads/... | kubectl exec -i -n cloud deploy/nextcloud -- \
  su -s /bin/sh www-data -c 'while IFS= read -r p; do
     php /var/www/html/occ files:delete -f "$p" || echo "FAIL: $p"; done'
```

`-f` is required: without it `files:delete` prompts and defaults to **no** when
stdin is not a terminal, so nothing happens.

Files go to the user's trashbin, so this is reversible, and `files_trashbin` is
on the same filesystem — **no space is freed until the trash is purged.**

### Result

3,017 files, 57.5 GiB, all photos/videos. 3,016 went to the trashbin; one
manifest entry was a stale cache row with no file behind it. Afterwards
`uploads` reconciled exactly: 1,261 entries on disk, 1,261 rows in cache.

### Expect transient failures under memory pressure

Each `files:delete` spawns a full PHP bootstrap (~3s, ~20 files/min), so a few
thousand files take hours. A long background run was killed when the host ran
low on memory, and the chunks around that point reported failures — 110 of 111
in one — that were **not** data problems: every one succeeded on retry once
memory recovered.

So: re-derive what is left from `oc_filecache` rather than trusting a failure
list, and retry. Some failures also move the file to the trashbin while still
exiting non-zero, which is why the cache is the source of truth, not the exit
code. Prefer short foreground chunks over one long background job.
