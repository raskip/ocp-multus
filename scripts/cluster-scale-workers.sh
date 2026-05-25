#!/usr/bin/env bash
# Stop or start ONLY the worker VMs (including the SR-IOV worker), leaving the
# control plane up. Cheaper than a full shutdown when you only want to pause
# workload compute, but keeps the API and etcd reachable so cluster-admin tasks
# still work.
#
# Subcommands:
#   down    cordon + drain workers, in-OS shutdown, wait until Azure reports
#           workers stopped/deallocated, then `az vm deallocate` worker VMs.
#           Refuses to deallocate if workers did not gracefully stop in time.
#   up      `az vm start` workers, wait Ready, auto-approve kubelet CSRs,
#           uncordon.
#   status  show worker Azure power state alongside node Ready/SchedulingDisabled.
#
# Usage:
#   scripts/cluster-scale-workers.sh down   [--yes] [--timeout <min>] [--dry-run]
#   scripts/cluster-scale-workers.sh up     [--no-approve] [--skip-uncordon]
#                                           [--timeout <min>] [--dry-run]
#   scripts/cluster-scale-workers.sh status
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SUB="${1:-}"; [[ -n "$SUB" ]] && shift || true
case "$SUB" in
  down|up|status) ;;
  -h|--help|"") sed -n '2,19p' "$0"; exit 0 ;;
  *) log_err "unknown subcommand: $SUB"; exit 2 ;;
esac

NO_APPROVE=0
SKIP_UNCORDON=0
TIMEOUT_MIN=""

while (( $# > 0 )); do
  case "$1" in
    --yes|-y)        ASSUME_YES=1; shift ;;
    --no-approve)    NO_APPROVE=1; shift ;;
    --skip-uncordon) SKIP_UNCORDON=1; shift ;;
    --timeout)       TIMEOUT_MIN=$(flag_value "--timeout" "${2:-}"); shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) log_err "unknown flag: $1"; exit 2 ;;
  esac
done

load_config
: "${TIMEOUT_MIN:=$OPERATIONS_TIMEOUT_MIN}"
require_az
require_cmd jq

WORKER_ROLES=(worker sriov-worker)

case "$SUB" in
  status)
    log_step "worker VM power state"
    vm_inventory | awk -F'\t' 'BEGIN{printf "%-14s %-44s %s\n","ROLE","NAME","POWER"} $1 ~ /^(worker|sriov-worker)$/ {printf "%-14s %-44s %s\n",$1,$2,$3}' >&2
    if oc whoami >/dev/null 2>&1; then
      log_step "worker node status (cluster view)"
      oc get nodes -l node-role.kubernetes.io/worker -o wide || true
    else
      log_warn "oc not logged in; skipping cluster view"
    fi
    exit 0
    ;;
  down)
    require_oc
    log_step "Azure worker inventory"
    vm_inventory | awk -F'\t' '$1 ~ /^(worker|sriov-worker)$/' >&2

    confirm "Cordon + drain workers and deallocate worker VMs? Masters stay up." \
      || { log_err "aborted"; exit 1; }

    log_step "cordoning worker nodes"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would cordon all worker nodes"
    else
      for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
        log_info "cordon $n"
        oc adm cordon "$n" >/dev/null
      done
    fi

    log_step "draining worker nodes"
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would drain all worker nodes"
    else
      for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
        log_info "drain $n"
        oc adm drain "$n" \
          --delete-emptydir-data --ignore-daemonsets --force --timeout=15s \
          || log_warn "drain of $n returned non-zero (continuing)"
      done
    fi

    log_step "shutting down workers in-OS before deallocate"
    for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
      if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[dry-run] would: oc debug node/$n -- chroot /host shutdown -h 1"
      else
        log_info "shutdown -h 1 on $n"
        oc debug "node/$n" --quiet --to-namespace=default -- chroot /host shutdown -h 1 \
          || log_warn "shutdown on $n returned non-zero (node may already be going down)"
      fi
    done

    if [[ "$DRY_RUN" != "1" ]]; then
      log_step "waiting for Azure to report worker VMs stopped or deallocated"
      if ! wait_for_vms_stopped "$TIMEOUT_MIN" "${WORKER_ROLES[@]}"; then
        log_err "refusing to deallocate workers that did not gracefully stop"
        log_err "investigate stuck VM(s) and re-run, or deallocate manually if you accept the risk"
        exit 1
      fi
    fi

    log_step "deallocating worker VMs"
    ids=$(vm_id_list "${WORKER_ROLES[@]}")
    if [[ -z "$ids" ]]; then
      log_warn "no worker VMs to deallocate"
      exit 0
    fi
    # shellcheck disable=SC2206
    ids_arr=( $ids )
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would: az vm deallocate --ids <${#ids_arr[@]} workers>"
      printf '  %s\n' "${ids_arr[@]}" >&2
    else
      az vm deallocate --ids "${ids_arr[@]}" --no-wait
      log_info "deallocate initiated for ${#ids_arr[@]} worker VMs"
    fi
    ;;
  up)
    log_step "starting worker VMs"
    ids=$(vm_id_list "${WORKER_ROLES[@]}")
    if [[ -z "$ids" ]]; then
      log_warn "no worker VMs to start"
      exit 0
    fi
    # shellcheck disable=SC2206
    ids_arr=( $ids )
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would: az vm start --ids <${#ids_arr[@]} workers>"
      printf '  %s\n' "${ids_arr[@]}" >&2
      exit 0
    fi
    az vm start --ids "${ids_arr[@]}"

    require_oc
    if (( NO_APPROVE == 1 )); then
      AUTO_APPROVE_CSRS=0
      log_warn "CSR auto-approval disabled (--no-approve)"
    else
      AUTO_APPROVE_CSRS=1
      approve_node_csrs >/dev/null
    fi

    log_step "waiting for worker nodes to become Ready"
    wait_for_nodes_ready "node-role.kubernetes.io/worker" "$TIMEOUT_MIN"

    if (( SKIP_UNCORDON == 1 )); then
      log_warn "skipping uncordon (--skip-uncordon)"
    else
      log_step "uncordoning worker nodes"
      for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
        log_info "uncordon $n"
        oc adm uncordon "$n" >/dev/null
      done
    fi

    log_step "summary"
    oc get nodes -l node-role.kubernetes.io/worker -o wide || true
    ;;
esac
