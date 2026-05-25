#!/usr/bin/env bash
# Restart a self-managed OpenShift cluster that was gracefully shut down
# (and deallocated in Azure) by scripts/cluster-shutdown.sh.
#
# Follows the Red Hat procedure:
#   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/graceful-restart-cluster
#
#   1. `az vm start` the control plane VMs.
#   2. `az vm start` the worker VMs (and SR-IOV worker).
#   3. Wait for the Kubernetes API to respond.
#   4. Loop-approve pending kubelet-client / kubelet-serving CSRs for
#      system:node:* requesters (unless --no-approve).
#   5. Wait until every control plane and worker node reports Ready.
#   6. Uncordon every node (unless --skip-uncordon).
#   7. Wait until every clusteroperator is Available / !Progressing / !Degraded.
#
# Usage:
#   scripts/cluster-startup.sh [--no-approve] [--skip-uncordon]
#                              [--timeout <minutes>] [--dry-run]
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

NO_APPROVE=0
SKIP_UNCORDON=0
TIMEOUT_MIN=""

while (( $# > 0 )); do
  case "$1" in
    --no-approve)    NO_APPROVE=1; shift ;;
    --skip-uncordon) SKIP_UNCORDON=1; shift ;;
    --timeout)       TIMEOUT_MIN=$(flag_value "--timeout" "${2:-}"); shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,19p' "$0"; exit 0 ;;
    *)
      log_err "unknown flag: $1"; exit 2 ;;
  esac
done

load_config
: "${TIMEOUT_MIN:=$OPERATIONS_TIMEOUT_MIN}"
require_az
require_cmd jq

log_step "Azure VM inventory in resource group $WORKLOAD_RESOURCE_GROUP"
INVENTORY=$(vm_inventory)
printf '%s\n' "$INVENTORY" | awk -F'\t' 'BEGIN{printf "%-14s %-44s %s\n","ROLE","NAME","POWER"} {printf "%-14s %-44s %s\n",$1,$2,$3}' >&2

start_role() {
  local role="$1"
  local ids
  ids=$(vm_id_list "$role")
  if [[ -z "$ids" ]]; then
    log_warn "no VMs to start for role: $role"
    return 0
  fi
  # shellcheck disable=SC2206
  local arr=( $ids )
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would: az vm start --ids <${#arr[@]} $role VMs>"
    printf '  %s\n' "${arr[@]}" >&2
    return 0
  fi
  log_info "starting ${#arr[@]} $role VMs"
  az vm start --ids "${arr[@]}"
}

log_step "starting control plane VMs"
start_role master

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[dry-run] skipping API/CSR/uncordon/operator waits"
  log_info "[dry-run] would start workers after control plane reaches Ready"
  start_role worker
  start_role sriov-worker
  exit 0
fi

require_cmd oc

log_step "waiting for the Kubernetes API to respond (control plane just started)"
wait_for_api "$TIMEOUT_MIN"

require_oc

if (( NO_APPROVE == 1 )); then
  AUTO_APPROVE_CSRS=0
  log_warn "CSR auto-approval disabled (--no-approve); pending CSRs must be reviewed manually:"
  oc get csr || true
else
  AUTO_APPROVE_CSRS=1
  log_step "approving any pending kubelet CSRs (auto-approval loop)"
  # One quick pass; the wait loops below also call approve_node_csrs.
  approve_node_csrs >/dev/null
fi

log_step "waiting for control plane nodes to become Ready"
wait_for_nodes_ready "node-role.kubernetes.io/master" "$TIMEOUT_MIN"

log_step "starting worker VMs (including SR-IOV worker) now that control plane is Ready"
start_role worker
start_role sriov-worker

log_step "waiting for worker nodes to become Ready"
wait_for_nodes_ready "node-role.kubernetes.io/worker" "$TIMEOUT_MIN"

if (( SKIP_UNCORDON == 1 )); then
  log_warn "skipping uncordon (--skip-uncordon)"
else
  log_step "uncordoning all nodes"
  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    log_info "uncordon $node"
    oc adm uncordon "$node" >/dev/null
  done
fi

log_step "waiting for clusteroperators to converge"
wait_for_cluster_operators "$TIMEOUT_MIN" || log_warn "continuing despite operator warnings; check 'oc get co'"

log_step "etcd health"
etcd_health || log_warn "etcd health check did not pass; investigate before considering startup successful"

log_step "summary"
oc get nodes -o wide || true
echo
oc get co || true

log_info "cluster startup complete"
