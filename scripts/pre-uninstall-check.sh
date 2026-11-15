#!/usr/bin/env bash
# Run before k3s-uninstall.sh; exits non-zero if unsafe. See docs/OPERATIONS.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/common.sh
source "$SCRIPT_DIR/utils/common.sh"

usage() {
    cat << EOF
Usage: $0 <node> [--local-path-backed-up]

Checks, run from any machine with kubectl and SSH access to <node>:
  1. Node is drained (or already deleted from the cluster)
  2. Nothing mounted under /var/lib/kubelet or /var/lib/rancher on the node
  3. If the node is an etcd server: an etcd snapshot <24h old exists on another server
  4. Local-path data under /opt/local-path-provisioner is listed; pass
     --local-path-backed-up once it is backed up
EOF
}

node="${1:-}"
[[ -z "$node" || "$node" == -* ]] && { usage; exit 1; }
shift
backed_up=false
[[ "${1:-}" == "--local-path-backed-up" ]] && backed_up=true

failures=0
on_node() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$@"; }
fail() { log_error "$1"; failures=$((failures + 1)); }

log_step "Pre-uninstall check: $node"

if kubectl get node "$node" >/dev/null 2>&1; then
    if [[ "$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}')" != "true" ]]; then
        fail "Node is not cordoned. Run: scripts/manage-nodes.sh drain $node"
    fi
    pods=$(kubectl get pods -A --field-selector "spec.nodeName=$node,status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.ownerReferences[0].kind}{"\n"}{end}' \
        | awk '$2 != "DaemonSet" {print $1}')
    if [[ -n "$pods" ]]; then
        fail "Non-DaemonSet pods still running on $node:"
        echo "$pods" | sed 's/^/    /'
    else
        log_success "No workload pods running"
    fi
else
    log_info "Node not in cluster (already deleted); skipping drain check"
fi

if mounts=$(on_node \
    "awk '\$2 ~ \"^/var/lib/(kubelet|rancher)\" {print \$3, \$2}' /proc/mounts"); then
    if [[ -n "$mounts" ]]; then
        fail "Mounts remain under /var/lib/kubelet or /var/lib/rancher (DaemonSet pods keep theirs after a drain). On the node run: sudo /usr/local/bin/k3s-killall.sh, then re-check:"
        echo "$mounts" | sed 's/^/    /'
    else
        log_success "No mounts under /var/lib/kubelet or /var/lib/rancher"
    fi
else
    fail "Could not read /proc/mounts on $node over SSH"
fi

if on_node "test -f /etc/systemd/system/k3s.service"; then
    recent=$(kubectl get etcdsnapshotfiles -o json | jq -r --arg n "$node" '.items[]
        | select(.spec.nodeName != $n and .status.readyToUse and (.status.creationTime | fromdateiso8601) > now - 86400)
        | "\(.spec.nodeName) \(.status.creationTime)"')
    if [[ -z "$recent" ]]; then
        fail "$node is a k3s server and no etcd snapshot <24h old exists on another server. Run on cyl-homelab: sudo k3s etcd-snapshot save"
    else
        log_success "Recent etcd snapshot on another server: $(head -1 <<<"$recent")"
    fi
fi

pvs=$(kubectl get pv -o json | jq -r --arg n "$node" '.items[]
    | select(.spec.storageClassName == "local-path")
    | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | index($n))
    | "\(.metadata.name) \(.spec.claimRef.namespace)/\(.spec.claimRef.name) reclaim=\(.spec.persistentVolumeReclaimPolicy)"')
if [[ -n "$pvs" ]]; then
    log_warning "Local-path volumes on $node (uninstall does not touch /opt/local-path-provisioner, back them up anyway):"
    echo "$pvs" | sed 's/^/    /'
    $backed_up || fail "Back up /opt/local-path-provisioner on $node, then re-run with --local-path-backed-up"
fi

if [[ $failures -gt 0 ]]; then
    log_error "$failures check(s) failed. Do NOT uninstall yet."
    exit 1
fi
log_success "Safe to uninstall k3s on $node"
