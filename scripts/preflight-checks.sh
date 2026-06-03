#!/usr/bin/env bash
# scripts/preflight-checks.sh
#
# Orchestrator for `make preflight`. Runs the nine sub-checks in order:
#   01-sp-roles.sh       Azure RBAC role assignments
#   02-vnet.sh           VNet + subnets
#   03-nsg.sh            NSG rules on cluster subnets
#   04-udr.sh            UDR attach (firewall egress)
#   05-quota.sh          D-series vCPU quota
#   06-dns-zone.sh       Parent DNS zone + delegation permission
#   07-peering.sh        spoke ↔ hub VNet peering (skipped if standalone)
#   08-fw-policy.sh      Azure Firewall policy (opt-in via FW_POLICY_*)
#   09-sp-json.sh        ~/.azure/osServicePrincipal.json
#
# Each sub-check is read-only and prints actionable [PASS|FAIL|WARN|SKIP]
# lines. The orchestrator prints a summary and exits non-zero only if
# any check reported FAIL.
#
# Run only a subset:
#   PREFLIGHT_INCLUDE="01,05,09" make preflight
#   PREFLIGHT_EXCLUDE="07,08"    make preflight

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=preflight/_lib.sh
source "$HERE/preflight/_lib.sh"

ALL=(
  "01-sp-roles.sh"
  "02-vnet.sh"
  "03-nsg.sh"
  "04-udr.sh"
  "05-quota.sh"
  "06-dns-zone.sh"
  "07-peering.sh"
  "08-fw-policy.sh"
  "09-sp-json.sh"
)

include_re=""
[[ -n "${PREFLIGHT_INCLUDE:-}" ]] && include_re="^(${PREFLIGHT_INCLUDE//,/|})-"
exclude_re=""
[[ -n "${PREFLIGHT_EXCLUDE:-}" ]] && exclude_re="^(${PREFLIGHT_EXCLUDE//,/|})-"

printf '%s\n' "Running OpenShift on Azure UPI preflight checks (read-only)"
printf '  config: %s\n' "${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"

for script in "${ALL[@]}"; do
  if [[ -n "$include_re" ]] && [[ ! "$script" =~ $include_re ]]; then
    continue
  fi
  if [[ -n "$exclude_re" ]] && [[ "$script" =~ $exclude_re ]]; then
    continue
  fi
  # shellcheck disable=SC1090
  source "$HERE/preflight/$script" || true
done

pf_dump_summary
