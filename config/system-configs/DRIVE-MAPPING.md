# Physical Drive to Logical Mount Mapping

**Last Updated:** 2025-09-30
**System:** cyl-homelab

## Storage Array Overview

- **Total Data Capacity:** ~6.8 TB (4 data drives)
- **Parity Capacity:** 3.6 TB (1 parity drive)
- **Array Type:** SnapRAID + MergerFS
- **Unified Mount:** `/media/data`

---

## Drive Mapping Table

| Physical | Size | Model | Serial | Partition | Label | UUID | Mount | Purpose |
|----------|------|-------|--------|-----------|-------|------|-------|---------|
| `/dev/sda` | 465.8G | ST3500830AS | 9QG5N35P | sda1 | data4 | f32cd179-7b68-42ef-81a6-dcf4e3e20968 | /mnt/data4 | **Data Drive 4** |
| `/dev/sdb` | 447.1G | KINGSTON SA400S37480G | 50026B7380689D75 | sdb1 | - | 5d0349bc-9c4b-4463-b21e-8ccaf6f861d1 | / | **OS Drive** (not in array) |
| `/dev/sdc` | 931.5G | WDC WD10EADX-00TDHB0 | WD-WCAV5S398441 | sdc1 | data3 | f3671b3e-6a45-4904-aec5-e5cfa774b64c | /mnt/data3 | **Data Drive 3** |
| `/dev/sdd` | 1.8T | ST2000DM006-2DM164 | Z560WFLZ | sdd1 | data2 | cade9ae8-5631-4ceb-9be4-af09085bcc8a | /mnt/data2 | **Data Drive 2** |
| `/dev/sde` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K5JFY8XT | sde1 | data1 | 53c59e25-4e9a-4c82-a83a-40941151e959 | /mnt/data1 | **Data Drive 1** (largest) |
| `/dev/sdf` | 3.6T | WDC WD40EFRX-68N32N0 | WD-WCC7K2UYA5A3 | sdf1 | parity1 | 813d8234-916d-42e1-89ce-cff117feab67 | /mnt/parity1 | **Parity Drive** (XFS) |

---

## Detailed Drive Information

### Data Drives (ext4)

#### Data Drive 1: `/dev/sde` → `/mnt/data1` (Largest)
- **Size:** 3.6 TB
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K5JFY8XT
- **Filesystem:** ext4
- **SnapRAID ID:** d1
- **Priority:** Highest (largest drive, used first by MergerFS)

#### Data Drive 2: `/dev/sdd` → `/mnt/data2`
- **Size:** 1.8 TB
- **Model:** Seagate ST2000DM006
- **Serial:** Z560WFLZ
- **Filesystem:** ext4
- **SnapRAID ID:** d2

#### Data Drive 3: `/dev/sdc` → `/mnt/data3`
- **Size:** 931.5 GB
- **Model:** Western Digital WD10EADX
- **Serial:** WD-WCAV5S398441
- **Filesystem:** ext4
- **SnapRAID ID:** d3

#### Data Drive 4: `/dev/sda` → `/mnt/data4`
- **Size:** 465.8 GB
- **Model:** Seagate ST3500830AS (older model)
- **Serial:** 9QG5N35P
- **Filesystem:** ext4
- **SnapRAID ID:** d4
- **Note:** Oldest drive in array

### Parity Drive (XFS)

#### Parity Drive: `/dev/sdf` → `/mnt/parity1`
- **Size:** 3.6 TB
- **Model:** Western Digital Red WD40EFRX
- **Serial:** WD-WCC7K2UYA5A3
- **Filesystem:** XFS (recommended for parity)
- **Purpose:** Stores parity information to recover from 1 drive failure
- **Note:** Must be ≥ largest data drive (matches sde at 3.6TB)

### OS Drive (Not in Array)

#### System Drive: `/dev/sdb` → `/`
- **Size:** 447.1 GB (Kingston SSD)
- **Model:** KINGSTON SA400S37480G
- **Serial:** 50026B7380689D75
- **Filesystem:** ext4
- **Purpose:** Operating system and applications
- **Not protected by SnapRAID** (separate backup strategy needed)

---

## MergerFS Configuration

**Unified Mount Point:** `/media/data`

**Source Drives (in order):**
1. `/mnt/data1` (3.6 TB) - sde
2. `/mnt/data2` (1.8 TB) - sdd
3. `/mnt/data3` (931 GB) - sdc
4. `/mnt/data4` (466 GB) - sda

**Policy:** `epmfs` (Existing Path, Most Free Space)
- Files are distributed across drives based on free space
- All drives appear as single `/media/data` directory

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

### If Data Drive Fails (sda, sdc, sdd, or sde)

1. **Identify failed drive** by serial number
2. **Replace with new drive** of equal or larger size
3. **Format as ext4** with same label
4. **Update /etc/fstab** with new UUID (if changed)
5. **Mount to same location** (e.g., `/mnt/data2`)
6. **Restore data:** `sudo snapraid fix -d d2`

### If Parity Drive Fails (sdf)

1. **Replace with 3.6TB+ drive**
2. **Format as XFS** with label "parity1"
3. **Update /etc/fstab** with new UUID
4. **Mount to /mnt/parity1**
5. **Rebuild parity:** `sudo snapraid sync`

### If OS Drive Fails (sdb)

- **Not protected by SnapRAID**
- Restore from separate backup
- Reinstall OS and restore configs from this repo
- Data array will be intact on other drives

---

## Monitoring Configuration

**Script:** `/home/cyl/homelab/scripts/monitor-storage.sh`
**Config:** `/home/cyl/homelab/config/service-configs/monitoring.conf`
**Cron:** Every 5 minutes via root crontab

**Monitored Drives:**
- SMART health: sda, sdc, sdd, sde, sdf
- Mount points: /mnt/data1, /mnt/data2, /mnt/data3, /mnt/data4, /mnt/parity1
- MergerFS pool: /media/data

**On Failure:**
- Scale k8s deployments to 0 (media, cloud namespaces)
- Unmount MergerFS pool
- Remount all drives read-only
- Send Discord alert

---

## Important Notes

1. **Drive Order Matters:** Physical device names (sda-sdf) can change on reboot. Always use UUIDs in /etc/fstab
2. **Parity Size:** Must be ≥ largest data drive (currently 3.6TB)
3. **Single Drive Protection:** SnapRAID can only recover from 1 drive failure at a time
4. **Not Real-Time:** New files are only protected after next `snapraid sync`
5. **OS Drive:** Not in array - backup separately
6. **Serial Numbers:** Use these to physically identify drives if failure occurs

---

## Physical Location Reference

To physically identify a failed drive:
1. Check serial number from monitoring alert
2. Cross-reference with table above
3. Drive serial numbers are printed on drive labels
4. WD-WCC* = Western Digital Red
5. Z560* = Seagate
6. 9QG5* = Older Seagate (most likely to fail first)

---

## Maintenance Commands

```bash
# View current drive status
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID

# Check physical drive info
sudo smartctl -i /dev/sda

# View SnapRAID status
sudo snapraid status

# Manual sync
sudo snapraid sync

# Check a specific drive's health
sudo smartctl -H /dev/sda
```

---

**Generated from system state on:** 2025-09-30
**Config files backed up in:** `/home/cyl/homelab/config/system-configs/`
