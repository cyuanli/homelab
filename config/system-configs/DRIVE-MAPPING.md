# Physical Drive to Logical Mount Mapping

**Last Updated:** 2026-08-21
**System:** cyl-homelab

> ⚠️ **`/dev/sdX` names are NOT stable.** They already changed once on this host:
> every letter in the 2025-09-30 revision of this file was wrong by 2026-08-21
> (only `sdc` happened to land on the same letter). **Identify drives by serial,
> UUID, or `/dev/disk/by-id/` path — never by letter.** Re-derive the table
> below after any reboot, drive swap, or cabling change:
>
> ```bash
> lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
> lsblk -d -o NAME,SIZE,MODEL,SERIAL
> ls -l /dev/disk/by-id/ | grep -v part
> ```
>
> `config/service-configs/monitoring.conf` also keys off `/dev/sdX` names —
> update it in the same pass or SMART checks will silently run against the wrong
> disk.

## Storage Array Overview

- **Total Data Capacity:** ~6.8 TB usable pool (4 data drives)
- **Parity Capacity:** 3.6 TB (1 parity drive)
- **Array Type:** SnapRAID + MergerFS
- **Unified Mount:** `/media/data`

---

## Drive Mapping Table

Current as of 2026-08-21. Sorted by device letter.

| Physical | Size | Model | Serial | Partition | Label | UUID | Mount | Purpose |
|----------|------|-------|--------|-----------|-------|------|-------|---------|
| `/dev/sda` | 447.1G | KINGSTON SA400S37480G | 50026B7380689D75 | sda1 | - | 5d0349bc-9c4b-4463-b21e-8ccaf6f861d1 | `/` | **OS Drive** (not in array) |
| `/dev/sdb` | 1.8T | ST2000DM006-2DM164 | Z560WFLZ | sdb1 | data2 | cade9ae8-5631-4ceb-9be4-af09085bcc8a | `/mnt/data2` | **Data Drive 2** |
| `/dev/sdc` | 931.5G | WDC WD10EADX-00TDHB0 | WD-WCAV5S398441 | sdc1 | data3 | f3671b3e-6a45-4904-aec5-e5cfa774b64c | `/mnt/data3` | **Data Drive 3** |
| `/dev/sdd` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K2UYA5A3 | sdd1 | parity1 | 813d8234-916d-42e1-89ce-cff117feab67 | `/mnt/parity1` | **Parity Drive** (XFS) |
| `/dev/sde` | 465.8G | ST3500830AS | 9QG5N35P | sde1 | data4 | f32cd179-7b68-42ef-81a6-dcf4e3e20968 | `/mnt/data4` | **Data Drive 4** |
| `/dev/sdf` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K5JFY8XT | sdf1 | data1 | 53c59e25-4e9a-4c82-a83a-40941151e959 | `/mnt/data1` | **Data Drive 1** (largest) |

`/dev/sdg`–`/dev/sdj` are the empty built-in USB card reader slots (0B) — ignore
them.

### Stable identifiers (`/dev/disk/by-id/`)

Use these in any script or procedure that must survive a reboot:

| Mount | Stable path |
|-------|-------------|
| `/mnt/data1` | `ata-WDC_WD40EFRX-68N32N0_WD-WCC7K5JFY8XT` |
| `/mnt/data2` | `ata-ST2000DM006-2DM164_Z560WFLZ` |
| `/mnt/data3` | `ata-WDC_WD10EADX-00TDHB0_WD-WCAV5S398441` |
| `/mnt/data4` | `ata-ST3500830AS_9QG5N35P` |
| `/mnt/parity1` | `ata-WDC_WD40EFRX-68N32N0_WD-WCC7K2UYA5A3` |
| `/` (OS) | `ata-KINGSTON_SA400S37480G_50026B7380689D75` |

`/etc/fstab` correctly uses UUIDs, so mounts are unaffected by letter changes.

---

## Detailed Drive Information

### Data Drives (ext4)

#### Data Drive 1 → `/mnt/data1` (Largest)
- **Size:** 3.6 TB (used 2.4T / 68% as of 2026-08-21)
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K5JFY8XT
- **Filesystem:** ext4
- **SnapRAID ID:** d1

#### Data Drive 2 → `/mnt/data2`
- **Size:** 1.8 TB (used 1.2T / 68%)
- **Model:** Seagate ST2000DM006
- **Serial:** Z560WFLZ
- **Filesystem:** ext4
- **SnapRAID ID:** d2

#### Data Drive 3 → `/mnt/data3`
- **Size:** 931.5 GB (used 304M / 1% — effectively empty)
- **Model:** Western Digital WD10EADX
- **Serial:** WD-WCAV5S398441
- **Filesystem:** ext4
- **SnapRAID ID:** d3

#### Data Drive 4 → `/mnt/data4`
- **Size:** 465.8 GB (used 227G / 53%)
- **Model:** Seagate ST3500830AS (older model)
- **Serial:** 9QG5N35P
- **Filesystem:** ext4
- **SnapRAID ID:** d4
- **Note:** Oldest drive in array

### Parity Drive (XFS)

#### Parity Drive → `/mnt/parity1`
- **Size:** 3.6 TB (used 2.7T / 72%)
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K2UYA5A3
- **Filesystem:** XFS (recommended for parity)
- **Purpose:** Stores parity information to recover from 1 drive failure
- **Note:** Must be ≥ largest data drive (matches data1 at 3.6TB)

### OS Drive (Not in Array)

#### System Drive → `/`
- **Size:** 447.1 GB (Kingston SSD); root partition 432G, used 92G / 23%
- **Model:** KINGSTON SA400S37480G
- **Serial:** 50026B7380689D75
- **Filesystem:** ext4 (+ 7.9G swap partition)
- **Purpose:** Operating system, applications, and `/srv/app-storage` — the SSD
  tier exported over NFS as `/exports/configs` (Immich thumbnails, encoded
  video, profile images; app configs)
- **Not protected by SnapRAID** (separate backup strategy needed — borgmatic)

---

## MergerFS Configuration

**Unified Mount Point:** `/media/data` (6.8T total, 3.8T used / 58%)

**Source Drives (branch order):**
1. `/mnt/data1` (3.6 TB)
2. `/mnt/data2` (1.8 TB)
3. `/mnt/data3` (931 GB)
4. `/mnt/data4` (466 GB)

**Live options** (`pgrep -a mergerfs`), mergerfs v2.42.0:
```
rw,noatime,direct_io,minfreespace=51G,category.create=epmfs,
moveonenospc=true,noforget,inodecalc=path-hash
```

- `epmfs` — Existing Path, Most Free Space
- `noforget` + `inodecalc=path-hash` — keep NFS file handles valid across a
  mergerfs remount (see `docs/STORAGE.md` → "Storage durability")

**Bind mounts served over NFS:**

| Bind | Source | fsid |
|------|--------|------|
| `/exports/media` | `/media/data` | 1 |
| `/exports/configs` | `/srv/app-storage` | 2 |
| `/exports/games` | `/media/data/games` | — (via pseudo-root) |

---

## SnapRAID Content Files

**Primary:** `/var/snapraid/snapraid.content`
**Backups (one per data drive):**
- `/mnt/data1/snapraid.content`
- `/mnt/data2/snapraid.content`
- `/mnt/data3/snapraid.content`
- `/mnt/data4/snapraid.content`

---

## Drive Failure Scenarios

Always confirm which physical drive failed **by serial**, not by the `/dev/sdX`
name in an alert — re-check the table above first.

### If a Data Drive Fails

1. **Identify the failed drive** by serial number
2. **Replace with new drive** of equal or larger size
3. **Format as ext4** with the same label (`data1`…`data4`)
4. **Update /etc/fstab** with the new UUID
5. **Mount to same location** (e.g. `/mnt/data2`)
6. **Restore data:** `sudo snapraid fix -d d2`
7. **Update this file and `config/service-configs/monitoring.conf`**

### If the Parity Drive Fails

1. **Replace with 3.6TB+ drive**
2. **Format as XFS** with label `parity1`
3. **Update /etc/fstab** with the new UUID
4. **Mount to /mnt/parity1**
5. **Rebuild parity:** `sudo snapraid sync`

### If the OS Drive Fails

- **Not protected by SnapRAID**
- Restore from borgmatic backup
- Reinstall OS and restore configs from this repo
- Data array will be intact on other drives
- Note this also loses `/srv/app-storage` (Immich thumbnails/encoded video are
  regenerable; app configs are not)

---

## Monitoring Configuration

**Script:** `/home/cyl/homelab/scripts/monitor-storage.sh`
**Config:** `/home/cyl/homelab/config/service-configs/monitoring.conf`
**Schedule:** every 5 minutes via **`disk-monitor.timer`** (systemd), deployed by
`ansible/playbooks/systemd-timers.yml`. This is not a cron job.

**Monitored:**
- SMART health for the 4 data drives + parity drive
- Mount points: `/mnt/data1`–`/mnt/data4`, `/mnt/parity1`
- MergerFS pool: `/media/data`
- Server-side NFS export layer (advisory only — never triggers lockdown)

**On drive failure (`lockdown_array`):**
- Stop all Docker containers
- Scale deployments to 0 in the `media` and `cloud` namespaces
- Unmount the MergerFS pool
- Remount all SnapRAID drives read-only
- Emit Prometheus metrics → Alertmanager → Discord

---

## Important Notes

1. **Drive Order Changes:** `/dev/sdX` names are assigned at boot and have
   already shifted once here. Always use UUIDs in `/etc/fstab` and serials or
   `by-id` paths everywhere else.
2. **Parity Size:** Must be ≥ largest data drive (currently 3.6TB)
3. **Single Drive Protection:** SnapRAID can only recover from 1 drive failure at a time
4. **Not Real-Time:** New files are only protected after the next `snapraid sync`
   (runs daily at 02:00 via `snapraid-runner.timer`)
5. **OS Drive:** Not in array - backup separately
6. **Serial Numbers:** Use these to physically identify drives if failure occurs

---

## Physical Location Reference

To physically identify a failed drive:
1. Check the serial number from the monitoring alert
2. Cross-reference with the table above
3. Drive serial numbers are printed on drive labels
4. `WD-WCC7K*` = Western Digital Red 4TB (two of them — **check the full serial**,
   `...5JFY8XT` is data1, `...2UYA5A3` is parity)
5. `WD-WCAV5*` = Western Digital 1TB (data3)
6. `Z560*` = Seagate 2TB (data2)
7. `9QG5*` = Older Seagate 500GB (data4, most likely to fail first)

---

## Maintenance Commands

```bash
# View current drive status
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID

# Map serials to current device letters
lsblk -d -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/ | grep -v part

# Check physical drive info (use by-id to be safe)
sudo smartctl -i /dev/disk/by-id/ata-ST3500830AS_9QG5N35P

# View SnapRAID status
sudo snapraid status

# Manual sync
sudo snapraid sync

# Check a specific drive's health
sudo smartctl -H /dev/disk/by-id/ata-ST3500830AS_9QG5N35P
```

---

**Generated from system state on:** 2026-08-21
**Config files backed up in:** `/home/cyl/homelab/config/system-configs/`
