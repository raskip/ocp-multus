#!/usr/bin/env bash
# scripts/preflight/04-udr.sh
#
# Verify the route table that routes egress through the firewall is
# attached to all OS subnets (master, worker, bootstrap, multus). In
# `outboundType: UserDefinedRouting` installs, the OpenShift installer
# expects every node-bearing subnet to have a UDR with a `0.0.0.0/0`
# next-hop to a NVA (Azure Firewall or third-party).
#
# Repo-managed mode: terraform/01-network/ today attaches the route
# table only to the worker subnet (Liite B B7). This check surfaces the
# gap so operators can extend it manually OR enable the BYO-network mode
# (PR-H) tfvars toggle attach_route_table_to_subnets=[...] when merged.
#
# BYO-network mode: the network team owns the route table and attach.
# This check still verifies they did it for every OS subnet.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "04: UDR attach on all OS subnets"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

: "${VIRTUAL_NETWORK:?VIRTUAL_NETWORK required}"
: "${NETWORK_RESOURCE_GROUP:?NETWORK_RESOURCE_GROUP required}"

SUB_ARGS=()
[[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]] && SUB_ARGS=(--subscription "$CLUSTER_SUBSCRIPTION_ID")

# All OS subnets that should have the route table attached.
SUBNETS_TO_CHECK=(
  "${CONTROL_PLANE_SUBNET:-snet-ocp-master}"
  "${COMPUTE_SUBNET:-snet-ocp-worker}"
  "${BOOTSTRAP_SUBNET:-snet-ocp-bootstrap}"
  "${MULTUS_SUBNET:-snet-ocp-multus}"
)

ROUTE_TABLE_IDS=()
for subnet in "${SUBNETS_TO_CHECK[@]}"; do
  rt=$(az network vnet subnet show \
    -g "$NETWORK_RESOURCE_GROUP" --vnet-name "$VIRTUAL_NETWORK" -n "$subnet" \
    "${SUB_ARGS[@]}" \
    --query routeTable.id -o tsv 2>/dev/null || true)
  if [[ -z "$rt" || "$rt" == "null" ]]; then
    pf_warn "subnet $subnet has NO route table — egress will go via Azure default (Internet) not the firewall"
    pf_info "fix: az network vnet subnet update -g $NETWORK_RESOURCE_GROUP --vnet-name $VIRTUAL_NETWORK -n $subnet --route-table <route-table-name>"
  else
    rt_name="${rt##*/}"
    pf_pass "subnet $subnet has route table $rt_name attached"
    ROUTE_TABLE_IDS+=("$rt")
  fi
done

# Cross-check the route table has a 0.0.0.0/0 route via VirtualAppliance.
if (( ${#ROUTE_TABLE_IDS[@]} > 0 )); then
  # de-dup the route table ids
  UNIQUE_RTS=$(printf '%s\n' "${ROUTE_TABLE_IDS[@]}" | sort -u)
  while IFS= read -r rt_id; do
    rt_name="${rt_id##*/}"
    rt_rg=$(echo "$rt_id" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1); exit}}')
    default_route=$(az network route-table route list -g "$rt_rg" --route-table-name "$rt_name" \
      "${SUB_ARGS[@]}" \
      --query "[?addressPrefix=='0.0.0.0/0']" -o json 2>/dev/null || echo '[]')
    next_hop_type=$(jq -r '.[0].nextHopType // empty' <<< "$default_route")
    next_hop_ip=$(jq -r   '.[0].nextHopIpAddress // empty' <<< "$default_route")
    if [[ -z "$next_hop_type" ]]; then
      pf_warn "route table $rt_name has NO 0.0.0.0/0 route — egress will follow Azure system route (Internet)"
      pf_info "fix: az network route-table route create -g $rt_rg --route-table-name $rt_name -n default-egress --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address <fw-private-ip>"
    elif [[ "$next_hop_type" == "VirtualAppliance" ]]; then
      pf_pass "route table $rt_name routes 0.0.0.0/0 to NVA at $next_hop_ip"
    else
      pf_warn "route table $rt_name has 0.0.0.0/0 with next-hop=$next_hop_type (expected VirtualAppliance for firewall egress)"
    fi
  done <<< "$UNIQUE_RTS"
fi

return 0
