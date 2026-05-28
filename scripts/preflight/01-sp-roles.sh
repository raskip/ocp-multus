#!/usr/bin/env bash
# scripts/preflight/01-sp-roles.sh
#
# Verify the Service Principal (or signed-in user) used for the OpenShift
# install has the correct Azure RBAC role assignments. Required scopes:
#   - Reader on the cluster subscription (install-time ARM validation)
#   - Contributor on the workload resource group (cluster runtime)
#   - Network Contributor on the VNet resource group (cluster runtime)
#
# Read-only: only `az role assignment list`. No mutations.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "01: Azure identity & role assignments"

pf_load_config || return 0
pf_require_cmd az "see docs/azure-credentials.md" || return 0
pf_require_cmd jq "apt install jq | brew install jq" || return 0

if ! az account show -o none >/dev/null 2>&1; then
  pf_fail "az not logged in"
  pf_info "fix: az login --use-device-code   # or set up the SP and run scripts/lib/common.sh require_az"
  return 0
fi

CLUSTER_SUB="${CLUSTER_SUBSCRIPTION_ID:-}"
if [[ -z "$CLUSTER_SUB" ]]; then
  CLUSTER_SUB=$(az account show --query id -o tsv)
  pf_warn "CLUSTER_SUBSCRIPTION_ID not set in config/cluster.env; using current az subscription $CLUSTER_SUB"
fi
WORKLOAD_RG="${WORKLOAD_RESOURCE_GROUP:?WORKLOAD_RESOURCE_GROUP required}"
NETWORK_RG="${NETWORK_RESOURCE_GROUP:-$WORKLOAD_RG}"
PRIVATE_DNS_SUB="${PRIVATE_DNS_SUBSCRIPTION_ID:-$CLUSTER_SUB}"
HUB_DNS_RG="${HUB_DNS_RESOURCE_GROUP:-$NETWORK_RG}"

# Resolve the principal id we're checking: SP if osServicePrincipal.json
# exists (matches what openshift-install would use), else the signed-in user.
PRINCIPAL_ID=""
PRINCIPAL_LABEL=""
SP_JSON="${AZURE_AUTH_LOCATION:-$HOME/.azure/osServicePrincipal.json}"
if [[ -f "$SP_JSON" ]]; then
  CLIENT_ID=$(jq -r '.clientId // empty' "$SP_JSON" 2>/dev/null || true)
  if [[ -n "$CLIENT_ID" ]]; then
    PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)
    PRINCIPAL_LABEL="SP $CLIENT_ID (from $SP_JSON)"
  fi
fi
if [[ -z "$PRINCIPAL_ID" ]]; then
  PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
  PRINCIPAL_LABEL="signed-in user $(az account show --query user.name -o tsv 2>/dev/null)"
fi

if [[ -z "$PRINCIPAL_ID" ]]; then
  pf_fail "cannot resolve principal id from osServicePrincipal.json nor az signed-in-user"
  pf_info "fix: az login   # or populate ~/.azure/osServicePrincipal.json — see docs/azure-credentials.md"
  return 0
fi
pf_info "checking principal: $PRINCIPAL_LABEL"

ROLES_JSON=$(az role assignment list --assignee "$PRINCIPAL_ID" --all -o json 2>/dev/null || echo '[]')

has_role() {
  local role="$1"; local scope="$2"
  jq --arg r "$role" --arg s "$scope" \
    'any(.[]; .roleDefinitionName == $r and (.scope | ascii_downcase | startswith($s | ascii_downcase)))' \
    <<< "$ROLES_JSON" 2>/dev/null | grep -q true
}

SUB_SCOPE="/subscriptions/$CLUSTER_SUB"
WL_SCOPE="$SUB_SCOPE/resourceGroups/$WORKLOAD_RG"
NET_SCOPE="$SUB_SCOPE/resourceGroups/$NETWORK_RG"
PDNS_SUB_SCOPE="/subscriptions/$PRIVATE_DNS_SUB"
PDNS_SCOPE="$PDNS_SUB_SCOPE/resourceGroups/$HUB_DNS_RG"

# Install-time: Reader on subscription is the minimum (Contributor / Owner
# also satisfy it via inheritance — check any of the three).
if has_role "Reader" "$SUB_SCOPE" || has_role "Contributor" "$SUB_SCOPE" || has_role "Owner" "$SUB_SCOPE"; then
  pf_pass "install-time read access on subscription $CLUSTER_SUB"
else
  pf_fail "no Reader/Contributor/Owner on $SUB_SCOPE"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role Reader --scope $SUB_SCOPE"
fi

# Runtime: Contributor on workload RG OR subscription-scope Contributor/Owner.
if has_role "Contributor" "$WL_SCOPE" || has_role "Owner" "$WL_SCOPE" \
  || has_role "Contributor" "$SUB_SCOPE" || has_role "Owner" "$SUB_SCOPE"; then
  pf_pass "runtime Contributor on workload RG $WORKLOAD_RG (or subscription)"
else
  pf_fail "no Contributor/Owner on $WL_SCOPE (cluster runtime needs this to create LBs / NSG rules / VM extensions)"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role Contributor --scope $WL_SCOPE"
fi

# Runtime: Network Contributor on VNet RG (only check if VNet RG differs
# from workload RG — otherwise the Contributor check above already covers).
if [[ "$WORKLOAD_RG" == "$NETWORK_RG" ]]; then
  pf_skip "network RG == workload RG — already covered by Contributor check above"
elif has_role "Network Contributor" "$NET_SCOPE" \
  || has_role "Contributor"         "$NET_SCOPE" \
  || has_role "Owner"               "$NET_SCOPE" \
  || has_role "Contributor"         "$SUB_SCOPE" \
  || has_role "Owner"               "$SUB_SCOPE"; then
  pf_pass "runtime Network Contributor on VNet RG $NETWORK_RG (or higher)"
else
  pf_fail "no Network Contributor/Contributor/Owner on $NET_SCOPE (ingress-operator needs this to create LB frontend IPs)"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role 'Network Contributor' --scope $NET_SCOPE"
fi

# Private DNS hub zone: terraform/01-network writes the storage private endpoint
# A-record and VNet link into privatelink.blob.core.windows.net. In enterprise
# tenants this is often owned by a separate hub/connectivity DNS RG/subscription.
if has_role "Private DNS Zone Contributor" "$PDNS_SCOPE" \
  || has_role "Contributor"              "$PDNS_SCOPE" \
  || has_role "Owner"                    "$PDNS_SCOPE" \
  || has_role "Contributor"              "$PDNS_SUB_SCOPE" \
  || has_role "Owner"                    "$PDNS_SUB_SCOPE"; then
  pf_pass "private DNS write access on $HUB_DNS_RG (or higher)"
else
  pf_fail "no Private DNS Zone Contributor/Contributor/Owner on $PDNS_SCOPE (storage Private Endpoint DNS A-record + VNet link need this)"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role 'Private DNS Zone Contributor' --scope $PDNS_SCOPE"
fi

return 0
