#!/usr/bin/env python3
"""Find files stored in both Nextcloud and Immich, matched by SHA-1 content hash.

Both applications already record a SHA-1 of every file they own, so the bulk of
the work is a database join rather than a walk of the 6.8T pool:

  - Immich  `asset.checksum`      bytea, SHA-1 of the original. Complete.
  - Nextcloud `oc_filecache.checksum`  'SHA1:<hex>'. Only ~27% populated, so the
    remainder is hashed from disk.

Hashing every Nextcloud file would be ~941G. Instead the candidate set is first
reduced by file size: a file can only be a duplicate if some Immich asset has
exactly the same byte count. That leaves ~10k candidates (~77G), of which most
already carry a checksum in the database.

Nextcloud's data directory is mode 0750 www-data, unreadable by the invoking
user, so its files are hashed through `kubectl exec` into the Nextcloud pod.
Immich's library is world-readable on the storage host and is read directly.

Run on the storage node (cyl-homelab) with a working kubeconfig. Read-only: it
issues SELECTs and sha1sum, and writes only the output file.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from collections import defaultdict

# psql field/record separators. Nextcloud paths may contain any byte except NUL
# and '/', including newlines and '|', so the usual separators are unsafe.
FS = "\x01"
RS = "\x02"

IMMICH_DB = ("cloud", "app=immich-postgres", "immich", "immich")
NEXTCLOUD_DB = ("cloud", "app=postgres", "nextcloud", "nextcloud")

# The Nextcloud application pod, not its database — this is where the data
# directory is mounted and where files get hashed.
NEXTCLOUD_APP = ("cloud", "app=nextcloud")

# Container /data is the NFS PV whose host path is this. Verified by comparing
# asset.checksum against sha1sum of the mapped file.
IMMICH_DATA_HOST = "/media/data/immich/library"
IMMICH_DATA_CONTAINER = "/data"

# Nextcloud's datadirectory inside the pod, and the same tree on the host.
NEXTCLOUD_DATA_CONTAINER = "/var/www/html/data"
NEXTCLOUD_DATA_HOST = "/media/data/nextcloud"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def find_pod(namespace, selector):
    """Newest Running pod for a selector, excluding ones being torn down.

    Terminating pods still report phase=Running, hence the deletionTimestamp
    filter — same reasoning as scripts/backup-databases.sh.
    """
    tmpl = (
        '{{range .items}}{{if not .metadata.deletionTimestamp}}'
        '{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\\n"}}'
        "{{end}}{{end}}{{end}}"
    )
    out = subprocess.run(
        ["kubectl", "get", "pod", "-n", namespace, "-l", selector, "-o", f"go-template={tmpl}"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if not out:
        raise SystemExit(f"no Running pod for {namespace}/{selector}")
    return out[0]


def query(db, sql, fields):
    """Run a SELECT and return rows as lists of strings.

    Rows with the wrong field count are dropped: the runtime prepends an
    unrelated 'nvidia driver modules are not yet loaded' line to stdout on some
    nodes, which would otherwise corrupt the first record.
    """
    namespace, selector, user, dbname = db
    pod = find_pod(namespace, selector)
    proc = subprocess.run(
        ["kubectl", "exec", "-n", namespace, pod, "--",
         "psql", "-U", user, "-d", dbname, "-v", "ON_ERROR_STOP=1",
         "-t", "-A", "-F", FS, "-R", RS, "-c", sql],
        capture_output=True, text=True, check=True,
    )
    rows = []
    for record in proc.stdout.split(RS):
        record = record.strip("\n")
        if not record:
            continue
        parts = record.split(FS)
        if len(parts) == fields:
            rows.append(parts)
    return rows


def load_immich():
    """Every live Immich asset: id, host path, filename, sha1, size, owner."""
    rows = query(IMMICH_DB, """
        SELECT a.id,
               a."originalPath",
               a."originalFileName",
               encode(a.checksum, 'hex'),
               COALESCE(e."fileSizeInByte"::text, ''),
               COALESCE(u.email, '')
        FROM asset a
        LEFT JOIN asset_exif e ON e."assetId" = a.id
        LEFT JOIN "user" u ON u.id = a."ownerId"
        WHERE a."deletedAt" IS NULL AND a.status = 'active'
    """, 6)

    assets = []
    for asset_id, path, filename, sha1, size, owner in rows:
        if path.startswith(IMMICH_DATA_CONTAINER + "/"):
            host = IMMICH_DATA_HOST + path[len(IMMICH_DATA_CONTAINER):]
        else:
            host = path
        assets.append({
            "asset_id": asset_id,
            "path": host,
            "original_filename": filename,
            "sha1": sha1,
            "size": int(size) if size else None,
            "owner": owner,
        })
    return assets


def fill_missing_sizes(assets):
    """Stat assets whose exif row has no fileSizeInByte.

    Without this they would be absent from the size set and any Nextcloud copy
    of them would be silently skipped by the prefilter.
    """
    filled = missing = 0
    for asset in assets:
        if asset["size"] is not None:
            continue
        try:
            asset["size"] = os.path.getsize(asset["path"])
            filled += 1
        except OSError:
            missing += 1
    if filled or missing:
        log(f"  {filled} asset sizes filled by stat, {missing} files unreadable")


def load_nextcloud():
    """Every file in a user home: user, storage-relative path, size, sha1.

    Restricted to 'files/', which excludes files_trashbin/ and files_versions/,
    and to home:: storages, which excludes the appdata caches.
    """
    rows = query(NEXTCLOUD_DB, """
        SELECT s.id,
               f.path,
               f.size,
               COALESCE(f.checksum, '')
        FROM oc_filecache f
        JOIN oc_storages s ON s.numeric_id = f.storage
        WHERE f.path LIKE 'files/%'
          AND s.id LIKE 'home::%'
          AND f.size > 0
          AND f.mimetype <> (
              SELECT id FROM oc_mimetypes WHERE mimetype = 'httpd/unix-directory'
          )
    """, 4)

    files = []
    for storage, path, size, checksum in rows:
        user = storage[len("home::"):]
        sha1 = checksum[5:].lower() if checksum.startswith("SHA1:") else None
        files.append({
            "user": user,
            "path": path,
            "size": int(size),
            "sha1": sha1,
            "container_path": f"{NEXTCLOUD_DATA_CONTAINER}/{user}/{path}",
            "host_path": f"{NEXTCLOUD_DATA_HOST}/{user}/{path}",
            "sha1_source": "nextcloud-db" if sha1 else None,
        })
    return files


def unescape_coreutils(path):
    """Undo the escaping sha1sum applies to paths containing \\ or newline."""
    out, i = [], 0
    while i < len(path):
        if path[i] == "\\" and i + 1 < len(path):
            nxt = path[i + 1]
            if nxt == "n":
                out.append("\n")
                i += 2
                continue
            if nxt == "\\":
                out.append("\\")
                i += 2
                continue
        out.append(path[i])
        i += 1
    return "".join(out)


def hash_in_pod(files, batch_size):
    """Hash Nextcloud files by running sha1sum inside the Nextcloud pod.

    Paths are passed NUL-delimited so that no filename can be split, and
    sha1sum's own output escaping is reversed to recover the original path.

    Files that stay unhashed are left with sha1 None; sha1sum's per-file errors
    are not echoed because oc_filecache carries thousands of rows for files that
    no longer exist on disk, and the report lists them instead.
    """
    if not files:
        return
    namespace, selector = NEXTCLOUD_APP
    pod = find_pod(namespace, selector)
    by_container = {f["container_path"]: f for f in files}
    total = len(files)
    done = 0
    started = time.time()

    for start in range(0, total, batch_size):
        batch = files[start:start + batch_size]
        stdin = "\0".join(f["container_path"] for f in batch) + "\0"
        proc = subprocess.run(
            ["kubectl", "exec", "-i", "-n", namespace, pod, "--",
             "xargs", "-0", "sha1sum", "--"],
            input=stdin, capture_output=True, text=True,
        )
        for line in proc.stdout.splitlines():
            escaped = line.startswith("\\")
            if escaped:
                line = line[1:]
            digest, _, path = line.partition("  ")
            if not path:
                continue
            if escaped:
                path = unescape_coreutils(path)
            target = by_container.get(path)
            if target is not None:
                target["sha1"] = digest
                target["sha1_source"] = "hashed"
        done += len(batch)
        rate = done / max(time.time() - started, 1e-9)
        log(f"  hashed {done}/{total} ({rate:.0f} files/s)")


def drop_missing(files, batch_size):
    """Remove candidates whose file is not on disk, returning (kept, missing).

    A file hashed in the pod proves its own existence, but one whose SHA-1 came
    from oc_filecache does not: a stale cache row can carry a checksum for a
    file that was deleted outside Nextcloud, and taking it at face value puts a
    phantom into the report. Rare in practice — one entry in a 3,017-file
    cyl/uploads manifest (2026-09-25) — but a phantom is indistinguishable from
    a real duplicate downstream, so it is cheaper to check than to explain.
    """
    if not files:
        return [], []
    namespace, selector = NEXTCLOUD_APP
    pod = find_pod(namespace, selector)
    present = set()

    for start in range(0, len(files), batch_size):
        batch = files[start:start + batch_size]
        stdin = "\0".join(f["container_path"] for f in batch) + "\0"
        proc = subprocess.run(
            ["kubectl", "exec", "-i", "-n", namespace, pod, "--",
             "xargs", "-0", "sh", "-c",
             'for p in "$@"; do [ -e "$p" ] && printf "%s\\0" "$p"; done', "sh"],
            input=stdin, capture_output=True, text=True,
        )
        present.update(p for p in proc.stdout.split("\0") if p)

    kept = [f for f in files if f["container_path"] in present]
    missing = [f for f in files if f["container_path"] not in present]
    return kept, missing


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-o", "--output", default="nextcloud-immich-duplicates.json",
                        help="where to write the JSON report")
    parser.add_argument("--no-size-filter", action="store_true",
                        help="hash every Nextcloud file instead of only those whose "
                             "size matches an Immich asset (~941G of reads)")
    parser.add_argument("--rehash", action="store_true",
                        help="ignore checksums stored by Nextcloud and hash from disk")
    parser.add_argument("--batch-size", type=int, default=500,
                        help="paths per sha1sum invocation in the pod")
    args = parser.parse_args()

    log("Loading Immich assets...")
    assets = load_immich()
    fill_missing_sizes(assets)
    log(f"  {len(assets)} live assets")

    log("Loading Nextcloud files...")
    nc_files = load_nextcloud()
    log(f"  {len(nc_files)} files in user homes")

    if args.rehash:
        for f in nc_files:
            f["sha1"] = None
            f["sha1_source"] = None

    if args.no_size_filter:
        candidates = nc_files
    else:
        immich_sizes = {a["size"] for a in assets if a["size"] is not None}
        candidates = [f for f in nc_files if f["size"] in immich_sizes]
        log(f"  {len(candidates)} share a file size with an Immich asset")

    log("Checking candidates still exist on disk...")
    candidates, missing = drop_missing(candidates, args.batch_size)
    log(f"  {len(candidates)} present, {len(missing)} stale oc_filecache rows dropped")

    need_hash = [f for f in candidates if f["sha1"] is None]
    if need_hash:
        gib = sum(f["size"] for f in need_hash) / 1024 ** 3
        log(f"Hashing {len(need_hash)} files ({gib:.1f} GiB) in the Nextcloud pod...")
        hash_in_pod(need_hash, args.batch_size)

    assets_by_sha1 = defaultdict(list)
    for asset in assets:
        assets_by_sha1[asset["sha1"]].append(asset)

    matches = []
    for sha1, group in _group_by_sha1(candidates).items():
        immich_side = assets_by_sha1.get(sha1)
        if not immich_side:
            continue
        matches.append({
            "sha1": sha1,
            "size": group[0]["size"],
            "nextcloud": [{
                "user": f["user"],
                "path": f["path"],
                "host_path": f["host_path"],
                "sha1_source": f["sha1_source"],
            } for f in sorted(group, key=lambda f: (f["user"], f["path"]))],
            "immich": [{
                "asset_id": a["asset_id"],
                "owner": a["owner"],
                "original_filename": a["original_filename"],
                "path": a["path"],
            } for a in sorted(immich_side, key=lambda a: a["path"])],
        })

    matches.sort(key=lambda m: -m["size"])

    nc_copies = sum(len(m["nextcloud"]) for m in matches)
    duplicated_bytes = sum(m["size"] * len(m["nextcloud"]) for m in matches)
    unhashed = missing + [f for f in candidates if f["sha1"] is None]

    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "summary": {
            "immich_assets": len(assets),
            "nextcloud_files": len(nc_files),
            "nextcloud_candidates": len(candidates),
            "nextcloud_unreadable": len(unhashed),
            "matching_contents": len(matches),
            "nextcloud_copies_matched": nc_copies,
            "nextcloud_bytes_duplicated": duplicated_bytes,
            "size_filter": not args.no_size_filter,
        },
        "matches": matches,
        # Listed in oc_filecache but unreadable in the pod — almost all are rows
        # left behind for files deleted outside Nextcloud. They are candidates
        # whose duplicate status could not be decided either way.
        "nextcloud_unreadable": [
            {"user": f["user"], "path": f["path"], "size": f["size"]}
            for f in sorted(unhashed, key=lambda f: (f["user"], f["path"]))
        ],
    }

    with open(args.output, "w") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    log("")
    log(f"{len(matches)} contents present in both, "
        f"{nc_copies} Nextcloud files, "
        f"{duplicated_bytes / 1024 ** 3:.1f} GiB duplicated")
    if unhashed:
        log(f"{len(unhashed)} candidates are in oc_filecache but missing on disk "
            f"(listed under nextcloud_unreadable)")
    log(f"Report written to {args.output}")


def _group_by_sha1(files):
    grouped = defaultdict(list)
    for f in files:
        if f["sha1"]:
            grouped[f["sha1"]].append(f)
    return grouped


if __name__ == "__main__":
    main()
