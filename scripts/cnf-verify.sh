#!/usr/bin/env bash
# scripts/cnf-verify.sh
#
# Read-only post-deploy validation of the optional CNF / telco profile. Checks
# the appworker pool, node labels, ipvlan NADs, storage classes and the image
# registry. Mutates nothing.
#
# Usage: make cnf-verify   (or: bash scripts/cnf-verify.sh)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
set +e # continue on individual failures and summarise at the end
cd "$REPO_ROOT" || exit 1

PASS=0
FAIL=0
WARN=0
ok() {
  PASS=$((PASS + 1))
  printf '  [PASS] %s\n' "$*" >&2
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  [FAIL] %s\n' "$*" >&2
}
warn() {
  WARN=$((WARN + 1))
  printf '  [WARN] %s\n' "$*" >&2
}

log_step "CNF verify (read-only)"
require_cmd oc || {
  log_err "oc not found on PATH"
  exit 1
}
oc whoami >/dev/null 2>&1 || {
  log_err "oc is not logged in — log in as a cluster admin first"
  exit 1
}

# 1. appworker MachineConfigPool converged
if oc get mcp appworker >/dev/null 2>&1; then
  updated="$(oc get mcp appworker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null)"
  degraded="$(oc get mcp appworker -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)"
  mc="$(oc get mcp appworker -o jsonpath='{.status.machineCount}' 2>/dev/null)"
  uc="$(oc get mcp appworker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null)"
  if [[ "$updated" == "True" && "$degraded" != "True" ]]; then
    ok "MachineConfigPool/appworker Updated (machines ${uc:-?}/${mc:-?})"
  else
    bad "MachineConfigPool/appworker not converged (Updated=$updated Degraded=$degraded, ${uc:-?}/${mc:-?})"
  fi
else
  bad "MachineConfigPool/appworker not found — run 'make cnf-apply' first"
fi

# 2. appworker node labels
naw="$(oc get nodes -l node-role.kubernetes.io/appworker -o name 2>/dev/null | grep -c .)"
if [[ "${naw:-0}" -ge 1 ]]; then
  ok "$naw node(s) labeled node-role.kubernetes.io/appworker"
else
  bad "no nodes labeled node-role.kubernetes.io/appworker"
fi
nedge="$(oc get nodes -l is_edge=true -o name 2>/dev/null | grep -c .)"
[[ "${nedge:-0}" -ge 1 ]] && ok "$nedge node(s) labeled is_edge=true" || warn "no nodes labeled is_edge=true"

# 3. ipvlan NADs present in the cnf namespace
for nad in oam-ipvlan ausfudm-ipvlan hsshlr-ipvlan; do
  if oc -n cnf get net-attach-def "$nad" >/dev/null 2>&1; then
    ok "NetworkAttachmentDefinition cnf/$nad present"
  else
    bad "NetworkAttachmentDefinition cnf/$nad missing"
  fi
done

# 4. StorageClasses (RWO + RWX) — verify against the manifests, no hard-coded names
for f in manifests/storage/10-sc-azuredisk-rwo.yaml manifests/storage/20-sc-azurefile-rwx.yaml; do
  if [[ -f "$f" ]] && oc get -f "$f" >/dev/null 2>&1; then
    ok "StorageClass from $f present"
  else
    bad "StorageClass from $f missing (apply manifests/storage/)"
  fi
done

# 5. image registry Managed
mstate="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.managementState}' 2>/dev/null)"
if [[ "$mstate" == "Managed" ]]; then
  ok "image registry managementState=Managed"
else
  warn "image registry managementState=${mstate:-<unknown>} (expected Managed for the CNF profile; run scripts/configure-image-registry-managed.sh)"
fi

# 6. NIC ordering reminder (best-effort; needs oc debug privileges)
warn "verify worker NIC order (eth0=primary, eth1=oam, eth2=ausfudm, eth3=hsshlr): oc get nodes -l node-role.kubernetes.io/appworker -o name | xargs -I{} oc debug {} -- chroot /host ip -br a"

printf '\n  CNF verify summary: %d pass, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL" >&2
if [[ $FAIL -ne 0 ]]; then
  log_err "CNF verify found problems — see the [FAIL] items above."
  exit 1
fi
exit 0
