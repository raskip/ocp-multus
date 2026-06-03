#!/usr/bin/env bash
# scripts/preflight/03-nsg.sh
#
# Verify Network Security Groups for cluster subnets exist and at least
# permit the minimum ports OpenShift needs (6443/22623 master, 80/443
# worker). In repo-managed mode the NSGs are created by terraform/01-network
# so we skip if the subnets aren't there yet; in BYO-network mode the NSGs
# must exist and either be permissive or have the right rules.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "03: NSGs on cluster subnets"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

: "${VIRTUAL_NETWORK:?VIRTUAL_NETWORK required}"
: "${NETWORK_RESOURCE_GROUP:?NETWORK_RESOURCE_GROUP required}"

SUB_ARGS=()
[[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]] && SUB_ARGS=(--subscription "$CLUSTER_SUBSCRIPTION_ID")

check_subnet_nsg() {
  local subnet_name="$1"; local kind="$2"; shift 2
  local required_ports=("$@")  # e.g. "22 6443 22623" — strings, may contain dashes/ranges
  local nsg_id nsg_name nsg_rg rules
  nsg_id=$(az network vnet subnet show \
    -g "$NETWORK_RESOURCE_GROUP" --vnet-name "$VIRTUAL_NETWORK" -n "$subnet_name" \
    "${SUB_ARGS[@]}" \
    --query networkSecurityGroup.id -o tsv 2>/dev/null || true)
  if [[ -z "$nsg_id" ]]; then
    pf_warn "subnet $subnet_name ($kind) has no NSG (will be added by terraform/01-network in repo-managed mode; required in BYO-network mode)"
    return 0
  fi
  nsg_name="${nsg_id##*/}"
  nsg_rg=$(echo "$nsg_id" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1); exit}}')
  pf_pass "subnet $subnet_name has NSG $nsg_name (RG $nsg_rg)"

  rules=$(az network nsg show -g "$nsg_rg" -n "$nsg_name" "${SUB_ARGS[@]}" \
    --query 'securityRules[?direction==`Inbound` && access==`Allow`]' -o json 2>/dev/null || echo '[]')

  for port in "${required_ports[@]}"; do
    if jq -e --arg p "$port" '
      any(.[];
        (.destinationPortRange == $p)
        or (.destinationPortRanges // [] | any(. == $p))
        or (.destinationPortRange == "*")
        or ((.destinationPortRange | tostring) | test("^[0-9]+-[0-9]+$") and
           (($p | tonumber) >=
            (.destinationPortRange | split("-") | .[0] | tonumber)) and
           (($p | tonumber) <=
            (.destinationPortRange | split("-") | .[1] | tonumber)))
      )' <<< "$rules" >/dev/null 2>&1; then
      pf_pass "NSG $nsg_name allows inbound $port for $kind"
    else
      pf_warn "NSG $nsg_name does not visibly allow inbound $port for $kind (may still work via NSG hierarchy / Azure Policy)"
    fi
  done
}

# master subnet: API server (6443), Machine Config Server (22623), SSH debug (22)
check_subnet_nsg "${CONTROL_PLANE_SUBNET:-snet-ocp-master}" "control plane" 6443 22623 22

# worker subnet: HTTPS apps (443), HTTP apps (80), SSH debug (22)
check_subnet_nsg "${COMPUTE_SUBNET:-snet-ocp-worker}" "worker" 443 80 22

return 0
