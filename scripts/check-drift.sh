#!/usr/bin/env bash
# Compare repo manifests and Helm values against the live cluster, per object.
# Read-only. Exit: 0 no drift, 1 drift found.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
cd "$REPO" || exit 2

usage() {
    cat << EOF
Usage: $0 [-v]

Per-object diff of cluster/ against the live cluster, plus Helm values.
Objects are diffed one at a time so an immutable-selector error on one
Deployment doesn't hide drift in the rest of its kustomization.

  -v  show the changed lines, not just the changed field names
EOF
}

verbose=false
while getopts "vh" opt; do
    case "$opt" in
        v) verbose=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

split_objects() {
    python3 -I -c '
import sys, yaml
out, src = sys.argv[1], sys.argv[2].replace("/", "_")
for o in yaml.safe_load_all(sys.stdin):
    if not o or "kind" not in o:
        continue
    m = o["metadata"]
    parts = [src, o["kind"], m.get("namespace", "-"), m["name"]]
    yaml.safe_dump(o, open(out + "/" + "__".join(parts) + ".yaml", "w"))
' "$WORK" "$1"
}

# Kustomize roots: not included by a parent kustomization. boinc/base is only
# reachable through its overlays.
roots=()
while IFS= read -r k; do
    d="$(dirname "$k")"
    [[ "$(basename "$d")" == base ]] && continue
    p="$(dirname "$d")"; nested=false
    while [[ "$p" != . && "$p" != / ]]; do
        [[ -f "$p/kustomization.yaml" ]] && nested=true && break
        p="$(dirname "$p")"
    done
    $nested || roots+=("$d")
done < <(find cluster -name kustomization.yaml | sort)

for d in "${roots[@]}"; do
    kubectl kustomize "$d" 2>/dev/null | split_objects "$d"
done

# Standalone manifests: outside any kustomization, and not Helm values files.
while IFS= read -r f; do
    p="$(dirname "$f")"; covered=false
    while [[ "$p" != . && "$p" != / ]]; do
        [[ -f "$p/kustomization.yaml" ]] && covered=true && break
        p="$(dirname "$p")"
    done
    $covered && continue
    grep -qE '^kind:' "$f" || continue
    split_objects "$f" < "$f"
done < <(find cluster -name '*.yaml' ! -name 'kustomization.yaml' ! -name '*values*.yaml' | sort)

drift=0
shopt -s nullglob
for f in "$WORK"/*.yaml; do
    IFS='|' read -r src kind ns name <<< "$(basename "$f" .yaml | sed 's/__/|/g')"
    if [[ "$ns" == - ]]; then label="$kind $name"; else label="$kind $ns/$name"; fi
    out="$(kubectl diff -f "$f" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && continue
    drift=1

    nsflag=(); [[ "$ns" != - ]] && nsflag=(-n "$ns")
    if [[ $rc -gt 1 ]]; then
        if grep -q 'field is immutable' <<< "$out"; then
            live="$(kubectl get "$kind" "${nsflag[@]}" "$name" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)"
            echo "SELECTOR  $label  (live selector $live; repo labels differ, apply needs delete+recreate)"
        elif grep -qE 'namespaces? ".*" not found|no matches for kind' <<< "$out"; then
            echo "ABSENT    $label  ($(grep -oE 'namespaces? "[^"]*" not found|no matches for kind "[^"]*" in version "[^"]*"' <<< "$out" | head -1))"
        else
            echo "ERROR     $label  $(grep -vE '^\s*$' <<< "$out" | tail -1 | cut -c1-160)"
        fi
        continue
    fi

    if ! kubectl get "$kind" "${nsflag[@]}" "$name" >/dev/null 2>&1; then
        echo "ABSENT    $label  (in repo, not in cluster)"
        continue
    fi

    changed="$(grep -E '^[-+] ' <<< "$out" | grep -vE '^(\+\+\+|---) ' \
        | grep -vE '^[-+] +(generation|resourceVersion|uid|creationTimestamp):')"
    if [[ -z "$(grep -vE '^[-+]\s*#' <<< "$changed")" ]]; then
        echo "COMMENTS  $label"
        continue
    fi
    fields="$(grep -vE '^[-+]\s*#' <<< "$changed" | sed -E 's/^[-+] +(- )?//; s/:.*//' | sort -u | head -8 | paste -sd' ')"
    echo "DIFF      $label  [$fields]"
    if $verbose; then
        grep -vE '^[-+]\s*#' <<< "$changed" | head -20 | sed 's/^/            /'
    fi
done

# Helm: repo values file per release, as documented in INSTALLATION/OPERATIONS.
declare -A HELM_VALUES=(
    [automation/home-assistant]=cluster/applications/automation/home-assistant/values.yaml
    [cloud/immich]=cluster/applications/cloud/immich/values.yaml
    [monitoring/kube-prometheus-stack]=cluster/applications/monitoring/kube-prometheus-stack-values.yaml
    [monitoring/prometheus-blackbox-exporter]=cluster/applications/monitoring/blackbox-exporter-values.yaml
    [monitoring/smartctl-exporter]=cluster/applications/monitoring/smartctl-exporter-values.yaml
    [games/minecraft-apricorn]=cluster/applications/games/minecraft/worlds/apricorn-values.yaml
    [games/minecraft-sandstone]=cluster/applications/games/minecraft/worlds/sandstone-values.yaml
    [games/minecraft-cobblestone]=cluster/applications/games/minecraft/worlds/cobblestone-values.yaml
)
for rel in $(printf '%s\n' "${!HELM_VALUES[@]}" | sort); do
    ns="${rel%/*}"; name="${rel#*/}"; file="${HELM_VALUES[$rel]}"
    status="$(helm status -n "$ns" "$name" -o json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)"
    if [[ -z "$status" ]]; then
        echo "ABSENT    helm $rel"; drift=1; continue
    fi
    helm get values -n "$ns" "$name" -o yaml > "$WORK/live.yaml" 2>/dev/null
    result="$(python3 -I -c '
import sys, yaml
def flat(d, p=""):
    if isinstance(d, dict):
        r = {}
        for k, v in d.items():
            r.update(flat(v, f"{p}.{k}"))
        return r
    return {p: d}
a = flat(yaml.safe_load(open(sys.argv[1])) or {})
b = flat(yaml.safe_load(open(sys.argv[2])) or {})
print(" ".join(f"{k}(live={a.get(k)!s:.30} repo={b.get(k)!s:.30})" for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)))
' "$WORK/live.yaml" "$file")"
    if [[ -n "$result" ]]; then
        echo "DIFF      helm $rel  $result"; drift=1
    fi
    if [[ "$status" != deployed ]]; then
        echo "STATUS    helm $rel  $status"; drift=1
    fi
done

exit $drift
