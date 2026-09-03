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

This deploys disk-monitor + snapraid-runner to storage nodes, and auto-remediate to monitoring nodes.

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

```bash
# Create monitoring config from template
cp config/service-configs/monitoring.conf.template config/service-configs/monitoring.conf
# Edit with your drive configuration — see docs/CONFIGURATION.md
```

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
