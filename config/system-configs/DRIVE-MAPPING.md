# Physical Drive to Logical Mount Mapping

**Last Updated:** 2026-09-26
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

## Storage Array Overview

- **Total Data Capacity:** 9.9 TB pool (4 data drives)
- **Parity Capacity:** 5.5 TB (1 parity drive)
- **Array Type:** SnapRAID + MergerFS
- **Unified Mount:** `/media/data`

---

## Drive Mapping Table

Current as of 2026-09-26, after the parity swap. Sorted by device letter.

| Physical | Size | Model | Serial | Partition | Label | UUID | Mount | Purpose |
|----------|------|-------|--------|-----------|-------|------|-------|---------|
| `/dev/sda` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K2UYA5A3 | sda1 | data4 | 777e02e3-19f2-40a6-9015-7268e58c9068 | `/mnt/data4` | **Data Drive 4** (ex-parity) |
| `/dev/sdb` | 447.1G | KINGSTON SA400S37480G | 50026B7380689D75 | sdb1 | - | 5d0349bc-9c4b-4463-b21e-8ccaf6f861d1 | `/` | **OS Drive** (not in array) |
| `/dev/sdc` | 1.8T | ST2000DM006-2DM164 | Z560WFLZ | sdc1 | data2 | cade9ae8-5631-4ceb-9be4-af09085bcc8a | `/mnt/data2` | **Data Drive 2** |
| `/dev/sdd` | 931.5G | WDC WD10EADX-00TDHB0 | WD-WCAV5S398441 | sdd1 | data3 | f3671b3e-6a45-4904-aec5-e5cfa774b64c | `/mnt/data3` | **Data Drive 3** |
| `/dev/sde` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K5JFY8XT | sde1 | data1 | 53c59e25-4e9a-4c82-a83a-40941151e959 | `/mnt/data1` | **Data Drive 1** |
| `/dev/sdf` | 5.5T | WDC WD60EFZX-68B3FN0 | WD-C81MYRAK | sdf1 | parity1 | 744d3ce7-6c52-4e5a-a798-2b86a57e73d8 | `/mnt/parity1` | **Parity Drive** (XFS) |

`/dev/sdg`–`/dev/sdj` are the empty built-in USB card reader slots (0B) — ignore
them.

### Stable identifiers (`/dev/disk/by-id/`)

Use these in any script or procedure that must survive a reboot:

| Mount | Stable path |
|-------|-------------|
| `/mnt/data1` | `ata-WDC_WD40EFRX-68N32N0_WD-WCC7K5JFY8XT` |
| `/mnt/data2` | `ata-ST2000DM006-2DM164_Z560WFLZ` |
| `/mnt/data3` | `ata-WDC_WD10EADX-00TDHB0_WD-WCAV5S398441` |
| `/mnt/data4` | `ata-WDC_WD40EFRX-68N32N0_WD-WCC7K2UYA5A3` |
| `/mnt/parity1` | `ata-WDC_WD60EFZX-68B3FN0_WD-C81MYRAK` |
| `/` (OS) | `ata-KINGSTON_SA400S37480G_50026B7380689D75` |

`/etc/fstab` correctly uses UUIDs, so mounts are unaffected by letter changes.

---

## Detailed Drive Information

### Data Drives (ext4)

#### Data Drive 1 → `/mnt/data1`
- **Size:** 3.6 TB (used 3.4T / 94% as of 2026-09-26)
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K5JFY8XT
- **SnapRAID ID:** d1

#### Data Drive 2 → `/mnt/data2`
- **Size:** 1.8 TB (used 1.2T / 68%)
- **Model:** Seagate ST2000DM006
- **Serial:** Z560WFLZ
- **SnapRAID ID:** d2

#### Data Drive 3 → `/mnt/data3`
- **Size:** 931.5 GB (used 737G / 85%)
- **Model:** Western Digital WD10EADX
- **Serial:** WD-WCAV5S398441
- **SnapRAID ID:** d3

#### Data Drive 4 → `/mnt/data4`
- **Size:** 3.6 TB (used 227G / 7%)
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K2UYA5A3
- **SnapRAID ID:** d4
- **Note:** Was the parity drive until 2026-09-26. Rebuilt with
  `snapraid -d d4 fix`, which does not restore owner/permissions: the restored
  files are `root:root 600`. The previous data4 (Seagate ST3500830AS, serial
  9QG5N35P, 465.8 GB) is shelved with the original files.

### Parity Drive (XFS)

#### Parity Drive → `/mnt/parity1`
- **Size:** 5.5 TB (used 3.6T / 66%)
- **Model:** Western Digital Red Plus WD60EFZX (bought used)
- **Serial:** WD-C81MYRAK
- **Filesystem:** XFS
- **Note:** Must be ≥ largest data drive (3.6 TB)

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

**Unified Mount Point:** `/media/data` (9.9T total, 5.5T used / 57%)

**Source Drives (branch order):**
1. `/mnt/data1` (3.6 TB)
2. `/mnt/data2` (1.8 TB)
3. `/mnt/data3` (931 GB)
4. `/mnt/data4` (3.6 TB)

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
7. **Update this file** (the monitor finds disks from `/etc/snapraid.conf` itself)

### If the Parity Drive Fails

1. **Replace with a drive ≥ the largest data drive (3.6 TB)**
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

**Script:** `scripts/monitor-storage.sh`, run every 5 minutes by
**`disk-monitor.timer`** (systemd, deployed by `ansible/playbooks/systemd-timers.yml`).
It has no config file: it reads the data and parity disks from `/etc/snapraid.conf`
and resolves each mount to its device and serial at run time.

**Monitored:** SMART health, mount + write test, and kernel I/O / filesystem
errors for every SnapRAID disk; the MergerFS pool; the server-side NFS export
layer (advisory only — never triggers lockdown).

**On drive failure:** see `docs/STORAGE.md` → "How It Works".

---

## Important Notes

1. **Drive Order Changes:** `/dev/sdX` names are assigned at boot and have
   already shifted once here. Always use UUIDs in `/etc/fstab` and serials or
   `by-id` paths everywhere else.
2. **Parity Size:** Must be ≥ largest data drive (currently 3.6 TB; parity is 5.5 TB)
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
   `...5JFY8XT` is data1, `...2UYA5A3` is data4)
5. `WD-C81*` = Western Digital Red Plus 6TB (parity)
6. `WD-WCAV5*` = Western Digital 1TB (data3)
7. `Z560*` = Seagate 2TB (data2)

---

## Maintenance Commands

```bash
# View current drive status
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID

# Map serials to current device letters
lsblk -d -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/ | grep -v part

# Check physical drive info (use by-id to be safe)
sudo smartctl -i /dev/disk/by-id/ata-WDC_WD60EFZX-68B3FN0_WD-C81MYRAK

# View SnapRAID status
sudo snapraid status

# Manual sync
sudo snapraid sync

# Check a specific drive's health
sudo smartctl -H /dev/disk/by-id/ata-WDC_WD60EFZX-68B3FN0_WD-C81MYRAK
```

---

**Generated from system state on:** 2026-09-26
**Config files backed up in:** `/home/cyl/homelab/config/system-configs/`
