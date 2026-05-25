#!/usr/bin/env bash
# Read-only health snapshot of the cluster and its underlying Azure VMs.
# Safe to run at any time; never modifies anything.
#
# Reports:
#   - Azure VM inventory and power state
#   - kubeconfig context (oc whoami)
#   - Node Ready status
#   - clusteroperator status
#   - etcd member health (via etcdctl in an etcd pod)
#   - kube-apiserver-to-kubelet signer expiry (cluster-down-deadline)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

load_config
require_cmd jq

log_step "Azure VM inventory ($WORKLOAD_RESOURCE_GROUP)"
if require_az 2>/dev/null; then
  INV=$(vm_inventory || true)
  if [[ -n "$INV" ]]; then
    printf '%s\n' "$INV" \
      | awk -F'\t' 'BEGIN{printf "%-14s %-44s %s\n","ROLE","NAME","POWER"} {printf "%-14s %-44s %s\n",$1,$2,$3}' >&2
  else
    log_warn "no cluster VMs found matching naming pattern"
  fi
else
  log_warn "skipping Azure section (az not available or not logged in)"
fi

log_step "kubeconfig / cluster context"
if oc whoami >/dev/null 2>&1; then
  log_info "user:   $(oc whoami)"
  log_info "server: $(oc whoami --show-server)"
else
  log_warn "oc not logged in; cluster-side checks skipped"
  exit 0
fi

log_step "nodes"
oc get nodes -o wide || true

log_step "clusteroperators"
oc get co || true

log_step "etcd member health"
etcd_pod=$(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$etcd_pod" ]]; then
  oc -n openshift-etcd rsh -c etcdctl "$etcd_pod" \
    etcdctl endpoint health --cluster --write-out=table 2>&1 || log_warn "etcd health check failed"
else
  log_warn "no etcd pod available (control plane may be down)"
fi

log_step "certificate expiry"
EXPIRY=$(cert_expiry || true)
if [[ -n "$EXPIRY" ]]; then
  log_info "kube-apiserver-to-kubelet-signer not-after: $EXPIRY"
  log_info "(restart the cluster before that date to avoid manual CSR recovery)"
else
  log_warn "could not read certificate expiry"
fi
