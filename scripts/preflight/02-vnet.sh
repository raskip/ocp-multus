#!/usr/bin/env bash
# scripts/preflight/02-vnet.sh
#
# Verify the spoke VNet + required subnets exist and are reachable.
# Works in both modes:
#   - repo-managed network (terraform/01-network creates subnets):
#       only requires VNet to exist; subnets will be created by Terraform.
#   - BYO-network mode (subnets pre-created by the network team):
#       requires VNet + all 4-5 OS subnets to exist before `make network`.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "02: VNet + subnets"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

: "${VIRTUAL_NETWORK:?VIRTUAL_NETWORK required}"
: "${NETWORK_RESOURCE_GROUP:?NETWORK_RESOURCE_GROUP required}"

VNET_JSON=$(az network vnet show \
  -g "$NETWORK_RESOURCE_GROUP" -n "$VIRTUAL_NETWORK" \
  ${CLUSTER_SUBSCRIPTION_ID:+--subscription "$CLUSTER_SUBSCRIPTION_ID"} \
  -o json 2>/dev/null || true)

if [[ -z "$VNET_JSON" ]]; then
  pf_fail "VNet $VIRTUAL_NETWORK not found in RG $NETWORK_RESOURCE_GROUP"
  pf_info "fix: create the VNet ahead of time, or update VIRTUAL_NETWORK/NETWORK_RESOURCE_GROUP in config/cluster.env"
  return 0
fi
pf_pass "VNet $VIRTUAL_NETWORK exists in $NETWORK_RESOURCE_GROUP"

# Print CIDRs for operator review (informational).
CIDRS=$(jq -r '.addressSpace.addressPrefixes | join(", ")' <<< "$VNET_JSON")
pf_info "VNet address space: $CIDRS"

# Validate MACHINE_NETWORK_CIDR is contained in VNet address space (best-effort).
if [[ -n "${MACHINE_NETWORK_CIDR:-}" ]]; then
  if jq -e --arg m "$MACHINE_NETWORK_CIDR" \
       '.addressSpace.addressPrefixes | any(. == $m or startswith($m | split("/")[0]))' \
       <<< "$VNET_JSON" >/dev/null 2>&1; then
    pf_pass "MACHINE_NETWORK_CIDR $MACHINE_NETWORK_CIDR appears inside VNet address space"
  else
    pf_warn "MACHINE_NETWORK_CIDR $MACHINE_NETWORK_CIDR does not obviously match VNet address space ($CIDRS) — double-check"
  fi
fi

# Subnets: at minimum check the two named in cluster.env. In BYO-network
# mode the user would have all of master/worker/bootstrap/multus[/sriov]
# in place; in repo-managed mode they'll be created by terraform/01-network.
EXISTING_SUBNETS=$(jq -r '.subnets[].name' <<< "$VNET_JSON" 2>/dev/null || true)
pf_info "subnets currently in VNet: $(echo "$EXISTING_SUBNETS" | tr '\n' ' ')"

check_subnet() {
  local name="$1"; local kind="$2"
  if echo "$EXISTING_SUBNETS" | grep -qx "$name"; then
    pf_pass "subnet $name ($kind) exists"
  else
    pf_warn "subnet $name ($kind) NOT in VNet — Terraform will create it in repo-managed mode; required up-front in BYO-network mode"
  fi
}

check_subnet "${CONTROL_PLANE_SUBNET:-snet-ocp-master}" "control plane"
check_subnet "${COMPUTE_SUBNET:-snet-ocp-worker}"       "worker"

return 0
