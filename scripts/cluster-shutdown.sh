#!/usr/bin/env bash
# Gracefully shut down a self-managed OpenShift cluster running on Azure VMs
# and (by default) deallocate the VMs at the Azure layer to stop being billed
# for compute.
#
# Default mode (--graceful) follows the official Red Hat procedure:
#   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/graceful-shutdown-cluster
#
#   1. Preflight: require >=3 control plane nodes and warn on NotReady masters
#      (skip with --no-preflight).
#   2. Take an etcd backup (unless --no-backup).
#   3. Confirm (unless --yes / ASSUME_YES=1).
#   4. Cordon every node so no new pods land mid-shutdown.
#   5. Drain worker nodes (timeout per --drain-timeout, default 15s).
#   6. Issue `oc debug node/<name> -- chroot /host shutdown -h <SHUTDOWN_DELAY_MIN>`
#      on every node. A deterministic last control plane node is processed last
#      so the shutdown loop has a stable termination target.
#   7. Poll until Azure reports every cluster VM as PowerState/stopped or
#      PowerState/deallocated (up to --timeout minutes).
#   8. `az vm deallocate --no-wait` the cluster VMs in batch. If step 7 timed
#      out, the script REFUSES to deallocate unless --force-deallocate-after-timeout.
#
# --fast mode skips steps 1, 4-7 (no in-OS shutdown) and goes straight to
# `az vm deallocate` after confirmation and an optional backup. It is faster
# but can corrupt etcd if the cluster is under load. Use only when you
# understand the risk.
#
# Usage:
#   scripts/cluster-shutdown.sh [--graceful|--fast]
#                               [--no-backup] [--yes] [--no-preflight]
#                               [--timeout <minutes>]
#                               [--shutdown-delay-min <minutes>]
#                               [--drain-timeout <duration>]
#                               [--force-deallocate-after-timeout]
#                               [--dry-run]
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE="graceful"
DO_BACKUP=1
TIMEOUT_MIN=""
SHUTDOWN_DELAY_MIN=1
DRAIN_TIMEOUT="15s"
SKIP_PREFLIGHT=0
FORCE_DEALLOCATE_AFTER_TIMEOUT=0

while (( $# > 0 )); do
  case "$1" in
    --graceful) MODE="graceful"; shift ;;
    --fast)     MODE="fast";     shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --timeout)   TIMEOUT_MIN=$(flag_value "--timeout" "${2:-}") ; shift 2 ;;
    --shutdown-delay-min) SHUTDOWN_DELAY_MIN=$(flag_value "--shutdown-delay-min" "${2:-}") ; shift 2 ;;
    --drain-timeout) DRAIN_TIMEOUT=$(flag_value "--drain-timeout" "${2:-}") ; shift 2 ;;
    --no-preflight) SKIP_PREFLIGHT=1; shift ;;
    --force-deallocate-after-timeout) FORCE_DEALLOCATE_AFTER_TIMEOUT=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,35p' "$0"; exit 0 ;;
    *)
      log_err "unknown flag: $1"; exit 2 ;;
  esac
done

load_config
: "${TIMEOUT_MIN:=$OPERATIONS_TIMEOUT_MIN}"

if [[ "$MODE" == "graceful" ]]; then
  require_oc
fi
require_az
require_cmd jq

log_step "Azure VM inventory in resource group $WORKLOAD_RESOURCE_GROUP"
INVENTORY=$(vm_inventory)
if [[ -z "$INVENTORY" ]]; then
  log_err "no cluster VMs found in $WORKLOAD_RESOURCE_GROUP matching the configured naming pattern"
  log_err "verify CLUSTER_NAME / CONTROL_PLANE_VM_PREFIX / WORKER_VM_PREFIX / SRIOV_WORKER_VM_NAME"
  exit 1
fi
printf '%s\n' "$INVENTORY" | awk -F'\t' 'BEGIN{printf "%-14s %-44s %s\n","ROLE","NAME","POWER"} {printf "%-14s %-44s %s\n",$1,$2,$3}' >&2

# Filter out bootstrap (only exists during install) and any "other" rows.
TARGET_ROLES=(master worker sriov-worker)

if [[ "$MODE" == "graceful" ]]; then
  log_step "graceful shutdown"
  EXPIRY=$(cert_expiry || true)
  if [[ -n "$EXPIRY" ]]; then
    log_info "kube-apiserver-to-kubelet signer not-after: $EXPIRY"
    log_info "(restart the cluster before that date to avoid manual CSR recovery)"
  fi

  if (( SKIP_PREFLIGHT == 0 )); then
    preflight_shutdown_checks || {
      log_err "preflight failed; pass --no-preflight to override"
      exit 1
    }
  fi

  if (( DO_BACKUP == 1 )); then
    log_step "taking etcd backup (use --no-backup to skip)"
    DRY_RUN="$DRY_RUN" bash "$REPO_ROOT/scripts/cluster-etcd-backup.sh"
  else
    log_warn "skipping etcd backup (--no-backup); recovery from a bad restart will not be possible"
  fi

  confirm "Proceed to cordon + drain + shut down the cluster?" || { log_err "aborted"; exit 1; }

  log_step "cordoning all nodes"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would cordon every node"
  else
    for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
      log_info "cordon $node"
      oc adm cordon "$node" >/dev/null
    done
  fi

  log_step "draining worker nodes (timeout=$DRAIN_TIMEOUT)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would drain every worker node"
  else
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
      log_info "drain $node"
      oc adm drain "$node" \
        --delete-emptydir-data --ignore-daemonsets --force --timeout="$DRAIN_TIMEOUT" \
        || log_warn "drain of $node returned non-zero (continuing; pods will terminate at shutdown)"
    done
  fi

  log_step "ordering in-OS shutdown (workers first, deterministic master last)"
  LAST_MASTER=$(last_master_for_shutdown || true)
  log_info "last master in shutdown order: ${LAST_MASTER:-<unknown>}"
  log_info "(on Azure UPI the API VIP is on a Standard Load Balancer, not a master; this is just a deterministic ordering hint)"

  WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')
  MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}')

  ORDERED=()
  for n in $WORKER_NODES; do ORDERED+=("$n"); done
  for n in $MASTER_NODES; do
    [[ "$n" == "$LAST_MASTER" ]] && continue
    ORDERED+=("$n")
  done
  [[ -n "${LAST_MASTER:-}" ]] && ORDERED+=("$LAST_MASTER")

  for n in "${ORDERED[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would: oc debug node/$n -- chroot /host shutdown -h $SHUTDOWN_DELAY_MIN"
    else
      log_info "shutdown -h $SHUTDOWN_DELAY_MIN on $n"
      oc debug "node/$n" --quiet --to-namespace=default -- chroot /host shutdown -h "$SHUTDOWN_DELAY_MIN" \
        || log_warn "shutdown command on $n returned non-zero (node may already be going down)"
    fi
  done

  log_step "waiting for Azure to report all cluster VMs stopped or deallocated"
  all_stopped=0
  if wait_for_vms_stopped "$TIMEOUT_MIN" "${TARGET_ROLES[@]}"; then
    all_stopped=1
  fi

  if (( all_stopped == 0 )); then
    log_err "not all cluster VMs reached stopped state within ${TIMEOUT_MIN} minutes"
    log_err "remaining VMs:"
    vm_inventory | awk -F'\t' -v roles="${TARGET_ROLES[*]}" '
      BEGIN { split(roles, r, " "); for (i in r) want[r[i]] = 1 }
      { if (want[$1] && $3 !~ /[Ss]topped|[Dd]eallocated/) printf "  %s\t%s\n",$2,$3 }' >&2
    if (( FORCE_DEALLOCATE_AFTER_TIMEOUT == 0 )); then
      log_err "refusing to deallocate VMs that did not gracefully stop; etcd may be inconsistent"
      log_err "options:"
      log_err "  - investigate the stuck VM(s) and re-run scripts/cluster-shutdown.sh"
      log_err "  - re-run with --force-deallocate-after-timeout to deallocate anyway (NOT recommended)"
      log_err "  - run scripts/cluster-shutdown.sh --fast to hard-deallocate (etcd corruption risk)"
      exit 1
    fi
    log_warn "--force-deallocate-after-timeout: proceeding with deallocate despite stuck VMs"
  fi
fi

log_step "deallocating cluster VMs (releases compute billing; disks/NICs preserved)"
ids=$(vm_id_list "${TARGET_ROLES[@]}")
if [[ -z "$ids" ]]; then
  log_warn "no VM IDs to deallocate"
  exit 0
fi
# shellcheck disable=SC2206
ids_arr=( $ids )
if [[ "$MODE" == "fast" ]]; then
  log_warn "FAST MODE: skipping in-OS graceful shutdown. This can corrupt etcd."
  log_warn "Take an etcd backup first and only use this when the cluster is idle."
  confirm "Really deallocate ${#ids_arr[@]} VMs WITHOUT in-OS shutdown?$(
    (( DO_BACKUP == 1 )) && printf ' An etcd backup will be taken first.' || true)" \
    || { log_err "aborted"; exit 1; }
  if (( DO_BACKUP == 1 )); then
    log_step "taking etcd backup before deallocate (use --no-backup to skip)"
    DRY_RUN="$DRY_RUN" bash "$REPO_ROOT/scripts/cluster-etcd-backup.sh"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[dry-run] would: az vm deallocate --ids <${#ids_arr[@]} VMs>"
  printf '  %s\n' "${ids_arr[@]}" >&2
else
  az vm deallocate --ids "${ids_arr[@]}" --no-wait
  log_info "deallocate initiated for ${#ids_arr[@]} VMs (running in the background)"
fi

log_step "done"
log_info "to bring the cluster back up: make cluster-startup"
log_info "to bring back only workers:    make workers-up"
