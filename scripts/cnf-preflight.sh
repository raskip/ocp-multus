#!/usr/bin/env bash
# scripts/cnf-preflight.sh
#
# Read-only pre-flight checks before `make cnf-apply` enables the optional CNF /
# telco profile's in-cluster layer. Verifies the cluster + infra look ready and
# reminds you to fill the TODO(vendor) values. Mutates nothing.
#
# Usage: make cnf-preflight   (or: bash scripts/cnf-preflight.sh)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
set +e # this check continues on individual failures and summarises at the end
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

log_step "CNF preflight (read-only)"

# 1. CNF_PROFILE in config/cluster.env (read directly; avoids requiring a full
#    valid config for a read-only check).
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"
cnf_profile=""
if [[ -f "$CONFIG_FILE" ]]; then
  cnf_profile="$(grep -E '^[[:space:]]*CNF_PROFILE=' "$CONFIG_FILE" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
fi
if [[ "$cnf_profile" == "true" ]]; then
  ok "CNF_PROFILE=true in $CONFIG_FILE"
else
  warn "CNF_PROFILE is not 'true' in $CONFIG_FILE — the infra (3 LAN subnets + 4-NIC workers) may not be built. Merge config/cluster.cnf.example.env and re-run 'make all' first."
fi

# 2. oc available + logged in
if require_cmd oc 2>/dev/null && oc whoami >/dev/null 2>&1; then
  ok "oc logged in: $(oc whoami 2>/dev/null) @ $(oc whoami --show-server 2>/dev/null)"
  oc_ok=1
else
  bad "oc is not available / not logged in — log in as a cluster admin first"
  oc_ok=0
fi

# 3. CNF manifests present
missing=0
for d in cnf cnf-platform node-tuning storage; do
  [[ -d "$REPO_ROOT/manifests/$d" ]] || {
    warn "manifests/$d not found"
    missing=1
  }
done
[[ $missing -eq 0 ]] && ok "CNF manifests present (cnf, cnf-platform, node-tuning, storage)"

# 4. Worker nodes to label + NIC reminder (only if oc works)
if [[ "$oc_ok" == "1" ]]; then
  workers="$(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | grep -c .)"
  if [[ "${workers:-0}" -ge 1 ]]; then
    ok "found $workers worker node(s) that can become appworker nodes"
  else
    bad "no worker nodes found (node-role.kubernetes.io/worker)"
  fi
  warn "confirm each CNF worker has 4 NICs (eth0=primary, eth1=oam, eth2=ausfudm, eth3=hsshlr) — needs CNF_PROFILE=true at build time. Check: oc debug node/<w> -- chroot /host ip -br a"
fi

# 5. Vendor values reminder
warn "before 'make cnf-apply', fill the TODO(vendor) values (ipvlan mode/IPAM/static routes, sysctls, THP, capabilities/PriorityClass) — see docs/cnf-telco-profile.md 'Vendor values to confirm'."

printf '\n  CNF preflight summary: %d pass, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL" >&2
if [[ $FAIL -ne 0 ]]; then
  log_err "CNF preflight FAILED — resolve the [FAIL] items above before 'make cnf-apply'."
  exit 1
fi
exit 0
