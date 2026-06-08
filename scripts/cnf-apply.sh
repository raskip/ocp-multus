#!/usr/bin/env bash
# scripts/cnf-apply.sh
#
# Orchestrate the optional CNF / telco profile's post-install manifest sequence
# in the correct order, with MachineConfigPool convergence waits. Idempotent
# (oc apply). Run AFTER the cluster is installed with CNF_PROFILE=true.
#
#   CNF_YES=1                  skip the interactive confirmation prompt
#   DRY_RUN=1                  print the actions without applying anything
#   CNF_NODES="node-a node-b"  override which worker nodes get the appworker
#                              label (default: all node-role worker nodes)
#
# Usage: make cnf-apply   (or: bash scripts/cnf-apply.sh)
#
# IMPORTANT: fill the TODO(vendor) values in manifests/cnf and
# manifests/node-tuning first — see docs/cnf-telco-profile.md.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
set +e # step errors are handled explicitly via run()
cd "$REPO_ROOT" || exit 1

DRY_RUN="${DRY_RUN:-0}"
CNF_YES="${CNF_YES:-0}"

require_cmd oc || {
  log_err "oc not found on PATH"
  exit 1
}
oc whoami >/dev/null 2>&1 || {
  log_err "oc is not logged in — log in as a cluster admin first"
  exit 1
}

# Idempotent, DRY_RUN-aware command runner.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_info "+ $*"
  "$@" || {
    log_err "command failed: $*"
    exit 1
  }
}

# Wait for the appworker MachineConfigPool to converge (node-tuning rolls the
# pool one node at a time, with reboots).
wait_appworker_mcp() {
  local phase="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] oc wait mcp/appworker --for=condition=Updated --timeout=30m ($phase)"
    return 0
  fi
  log_info "waiting for MachineConfigPool/appworker to converge ($phase, up to 30m)..."
  sleep 15 # let the MCO notice the change before we wait on the condition
  oc wait mcp/appworker --for=condition=Updated --timeout=30m ||
    log_warn "appworker MCP did not report Updated within the timeout ($phase); inspect: oc get mcp appworker"
}

# Resolve the worker nodes to label as appworker.
if [[ -n "${CNF_NODES:-}" ]]; then
  # shellcheck disable=SC2206
  nodes=($CNF_NODES)
else
  mapfile -t nodes < <(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | sed 's|^node/||')
fi

log_step "CNF apply — post-install manifest sequence"
{
  echo "This applies the CNF in-cluster layer to the CURRENT cluster:"
  echo "  oc context : $(oc whoami 2>/dev/null) @ $(oc whoami --show-server 2>/dev/null)"
  echo "  appworker  : ${nodes[*]:-<none resolved>}"
  echo "  sequence   : namespace -> cnf-platform -> label nodes -> wait MCP"
  echo "               -> node-tuning -> wait MCP -> ipvlan NADs -> storage -> registry"
  echo "  DRY_RUN=$DRY_RUN  CNF_YES=$CNF_YES"
  echo
  echo "Ensure you have filled the TODO(vendor) values in manifests/cnf and"
  echo "manifests/node-tuning (docs/cnf-telco-profile.md 'Vendor values to confirm')."
} >&2

if [[ ${#nodes[@]} -eq 0 ]]; then
  log_err "no worker nodes resolved to label. Set CNF_NODES=\"n1 n2\" or check: oc get nodes -l node-role.kubernetes.io/worker"
  exit 1
fi

if [[ "$DRY_RUN" != "1" && "$CNF_YES" != "1" ]]; then
  read -r -p "Proceed with applying to this cluster? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || {
    log_warn "aborted by user (no changes made)"
    exit 0
  }
fi

# 1. namespace
run oc apply -f manifests/cnf/00-namespace.yaml
# 2. platform: appworker MCP, SCC, ServiceAccount, PriorityClass
run oc apply -f manifests/cnf-platform/
# 3. label the worker nodes into the appworker pool
for n in "${nodes[@]}"; do
  run oc label node "$n" node-role.kubernetes.io/appworker= --overwrite
  run oc label node "$n" is_worker=true --overwrite
  run oc label node "$n" is_edge=true --overwrite
done
# 4. wait for the pool to pick up the nodes
wait_appworker_mcp "nodes joining pool"
# 5. node tuning (SCTP, THP, sysctl allowlist, kubelet) -> triggers a rollout
run oc apply -f manifests/node-tuning/
# 6. wait for the tuning MachineConfigs to roll out
wait_appworker_mcp "node-tuning rollout"
# 7. ipvlan NADs (+ example pod)
run oc apply -f manifests/cnf/
# 8. storage classes (RWO + RWX)
run oc apply -f manifests/storage/
# 9. in-cluster image registry -> Managed
if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[dry-run] bash scripts/configure-image-registry-managed.sh"
else
  run bash scripts/configure-image-registry-managed.sh
fi

log_step "CNF apply complete"
log_info "validate with: make cnf-verify"
exit 0
