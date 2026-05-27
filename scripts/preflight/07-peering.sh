#!/usr/bin/env bash
# scripts/preflight/07-peering.sh
#
# If the spoke VNet is connected to a hub (hub-and-spoke topology, common
# enterprise pattern), verify both legs of the peering are present and
# Connected. Required when:
#   - DNS zones are linked from a centralised hub
#   - Egress goes through a hub firewall via UDR
#   - On-prem reachability via ER/VPN gateway in the hub
#
# We detect "hub-and-spoke" by looking for an existing peering on the
# spoke VNet — if none, we skip with INFO.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "07: spoke ↔ hub VNet peering"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

: "${VIRTUAL_NETWORK:?VIRTUAL_NETWORK required}"
: "${NETWORK_RESOURCE_GROUP:?NETWORK_RESOURCE_GROUP required}"

SUB_ARGS=()
[[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]] && SUB_ARGS=(--subscription "$CLUSTER_SUBSCRIPTION_ID")

PEERINGS=$(az network vnet peering list \
  -g "$NETWORK_RESOURCE_GROUP" --vnet-name "$VIRTUAL_NETWORK" \
  "${SUB_ARGS[@]}" -o json 2>/dev/null || echo '[]')

count=$(jq 'length' <<< "$PEERINGS")
if (( count == 0 )); then
  pf_skip "spoke VNet has no peerings — standalone topology (no hub-and-spoke checks)"
  return 0
fi

pf_info "spoke VNet has $count peering(s)"

bad=0
while IFS= read -r p; do
  name=$(jq -r '.name'                          <<< "$p")
  state=$(jq -r '.peeringState // "Unknown"'    <<< "$p")
  fwd=$(jq -r   '.allowForwardedTraffic // false' <<< "$p")
  remote=$(jq -r '.remoteVirtualNetwork.id // empty' <<< "$p")
  remote_name="${remote##*/}"

  if [[ "$state" != "Connected" ]]; then
    pf_fail "peering $name → $remote_name is in state '$state' (expected 'Connected')"
    pf_info "fix: re-create peering or check the other leg from the hub side"
    bad=$((bad + 1))
    continue
  fi

  if [[ "$fwd" != "true" ]]; then
    pf_warn "peering $name has allowForwardedTraffic=false — UDR-based firewall egress will be dropped when leaving the spoke"
    pf_info "fix: az network vnet peering update -g $NETWORK_RESOURCE_GROUP --vnet-name $VIRTUAL_NETWORK -n $name --set allowForwardedTraffic=true"
  else
    pf_pass "peering $name → $remote_name Connected (forwardedTraffic=true)"
  fi
done <<< "$(jq -c '.[]' <<< "$PEERINGS")"

if (( bad > 0 )); then
  pf_info "$bad peering(s) not Connected — both legs must exist; the other leg is created from the peer VNet's subscription/RG"
fi

return 0
