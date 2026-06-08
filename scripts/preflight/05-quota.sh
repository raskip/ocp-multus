#!/usr/bin/env bash
# scripts/preflight/05-quota.sh
#
# Verify the D-series family vCPU quota in the target region is large
# enough for a default cluster:
#   3x control plane @ 8 vCPU = 24
#   2x worker        @ 4 vCPU =  8
#   1x bootstrap     @ 4 vCPU =  4  (short-lived, but consumed during install)
#   uploader VM      @ 2 vCPU =  2
#   1x SR-IOV worker @ 8 vCPU =  8  (only if ENABLE_SRIOV=true)
#   Windows jump VM  @ 2 vCPU =  2  (only if CREATE_WINDOWS_JUMP=true)
# Required minimum: ~38 vCPU (46 with the SR-IOV worker). We warn under 60
# to give headroom for manual scaling / patch retries.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "05: D-series vCPU quota"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

: "${LOCATION:?LOCATION required}"

SUB_ARGS=()
[[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]] && SUB_ARGS=(--subscription "$CLUSTER_SUBSCRIPTION_ID")

# Pick the family from the configured VM sizes. The repo defaults to
# Standard_D*s_v5 (x86_64) or Standard_D*ps_v5 (arm64). We probe both.
FAMILIES=()
case "${ARCHITECTURE:-x86_64}" in
  arm64)  FAMILIES=("standardDPSv5Family") ;;
  *)      FAMILIES=("standardDSv5Family" "standardDv5Family") ;;
esac

MIN_REQUIRED=38
if [[ "${ENABLE_SRIOV:-false}" == "true" ]]; then
  MIN_REQUIRED=$((MIN_REQUIRED + 8))
fi
if [[ "${CREATE_WINDOWS_JUMP:-false}" == "true" ]]; then
  MIN_REQUIRED=$((MIN_REQUIRED + 2))
fi
MIN_RECOMMENDED=60

USAGE_JSON=$(az vm list-usage --location "$LOCATION" "${SUB_ARGS[@]}" -o json 2>/dev/null || echo '[]')
if [[ "$(jq 'length' <<< "$USAGE_JSON")" -eq 0 ]]; then
  pf_fail "az vm list-usage returned no data for region $LOCATION (auth/region issue?)"
  return 0
fi

found_any=0
for fam in "${FAMILIES[@]}"; do
  row=$(jq --arg f "$fam" '.[] | select(.name.value == $f)' <<< "$USAGE_JSON")
  if [[ -z "$row" || "$row" == "null" ]]; then
    continue
  fi
  found_any=1
  limit=$(jq -r '.limit'        <<< "$row")
  used=$(jq -r '.currentValue'  <<< "$row")
  available=$(( limit - used ))
  if (( available < MIN_REQUIRED )); then
    pf_fail "$fam in $LOCATION: $used/$limit used → $available available (need ≥ $MIN_REQUIRED)"
    pf_info "fix: request quota increase via az portal (Subscriptions > Usage + quotas) or 'az support tickets create'"
  elif (( available < MIN_RECOMMENDED )); then
    pf_warn "$fam in $LOCATION: $used/$limit used → $available available (passes minimum $MIN_REQUIRED; recommend ≥ $MIN_RECOMMENDED for headroom)"
  else
    pf_pass "$fam in $LOCATION: $available vCPU available (used $used / limit $limit)"
  fi
done

if (( found_any == 0 )); then
  pf_warn "no D-series family quota row found for $LOCATION — check that LOCATION/ARCHITECTURE match an Azure-supported region/family"
fi

# Also check the cores quota (sum across all families) — some subs have
# a regional cores cap that's lower than the family caps.
cores=$(jq '.[] | select(.name.value == "cores")' <<< "$USAGE_JSON")
if [[ -n "$cores" && "$cores" != "null" ]]; then
  c_limit=$(jq -r '.limit' <<< "$cores")
  c_used=$(jq -r  '.currentValue' <<< "$cores")
  c_avail=$(( c_limit - c_used ))
  if (( c_avail < MIN_REQUIRED )); then
    pf_fail "regional cores in $LOCATION: $c_used/$c_limit used → $c_avail available (need ≥ $MIN_REQUIRED)"
  else
    pf_pass "regional cores in $LOCATION: $c_avail vCPU available (used $c_used / limit $c_limit)"
  fi
fi

return 0
