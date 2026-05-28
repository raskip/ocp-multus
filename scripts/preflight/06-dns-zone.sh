#!/usr/bin/env bash
# scripts/preflight/06-dns-zone.sh
#
# Verify the parent DNS zone exists and is writable by the current
# identity. Required because terraform/00-prereqs creates the sub-zone
# (base_domain) as a child of parent_dns_zone and writes the NS
# delegation record. May live in a different subscription
# (dns_subscription_id) — we handle that via --subscription flags.
#
# Read-only — only `az network dns zone show` and a role-assignment
# probe. Does not create or modify any record.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "06: parent DNS zone + delegation permission"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

pf_load_tfvars 00-prereqs || true

PARENT_ZONE="${tfvars__parent_dns_zone:-}"
PARENT_RG="${tfvars__parent_dns_resource_group:-${DNS_RESOURCE_GROUP:-}}"
DNS_SUB="${tfvars__dns_subscription_id:-${DNS_SUBSCRIPTION_ID:-${CLUSTER_SUBSCRIPTION_ID:-}}}"
BASE_DOMAIN_FROM_TF="${tfvars__base_domain:-${BASE_DOMAIN:-}}"

if [[ -z "$PARENT_ZONE" || -z "$PARENT_RG" ]]; then
  pf_warn "parent_dns_zone or parent_dns_resource_group not set in terraform/00-prereqs/terraform.tfvars"
  pf_info "fix: cp terraform/00-prereqs/terraform.tfvars.example terraform/00-prereqs/terraform.tfvars && edit"
  return 0
fi

SUB_ARGS=()
[[ -n "$DNS_SUB" ]] && SUB_ARGS=(--subscription "$DNS_SUB")

ZONE_JSON=$(az network dns zone show -g "$PARENT_RG" -n "$PARENT_ZONE" "${SUB_ARGS[@]}" -o json 2>/dev/null || true)
if [[ -z "$ZONE_JSON" ]]; then
  pf_fail "parent DNS zone $PARENT_ZONE not found in RG $PARENT_RG (sub: ${DNS_SUB:-<current>})"
  pf_info "fix: create the zone or update parent_dns_zone/parent_dns_resource_group/dns_subscription_id in terraform/00-prereqs/terraform.tfvars"
  return 0
fi
pf_pass "parent DNS zone $PARENT_ZONE exists in $PARENT_RG"

ZONE_ID=$(jq -r '.id' <<< "$ZONE_JSON")
pf_info "zone id: $ZONE_ID"

# Check the current identity can write NS records on the parent zone.
# DNS Zone Contributor (or higher) on the zone or the RG is sufficient.
PRINCIPAL_ID=""
SP_JSON="${AZURE_AUTH_LOCATION:-$HOME/.azure/osServicePrincipal.json}"
if [[ -f "$SP_JSON" ]]; then
  CLIENT_ID=$(jq -r '.clientId // empty' "$SP_JSON" 2>/dev/null || true)
  if [[ -n "$CLIENT_ID" ]]; then
    PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)
  fi
fi
[[ -z "$PRINCIPAL_ID" ]] && PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

if [[ -z "$PRINCIPAL_ID" ]]; then
  pf_warn "cannot resolve principal id; skipping DNS write-permission probe"
  return 0
fi

WRITE_OK=$(az role assignment list --assignee "$PRINCIPAL_ID" --scope "$ZONE_ID" -o json 2>/dev/null \
  | jq -r 'any(.[]; .roleDefinitionName | IN("DNS Zone Contributor", "Contributor", "Owner"))')

if [[ "$WRITE_OK" != "true" ]]; then
  # fallback: check RG-level
  RG_SCOPE="/subscriptions/${DNS_SUB:-$(az account show --query id -o tsv)}/resourceGroups/$PARENT_RG"
  WRITE_OK=$(az role assignment list --assignee "$PRINCIPAL_ID" --scope "$RG_SCOPE" -o json 2>/dev/null \
    | jq -r 'any(.[]; .roleDefinitionName | IN("DNS Zone Contributor", "Contributor", "Owner"))')
fi

if [[ "$WRITE_OK" == "true" ]]; then
  pf_pass "current identity can write NS delegation to $PARENT_ZONE"
else
  pf_fail "current identity has no DNS Zone Contributor / Contributor / Owner on $PARENT_ZONE"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role 'DNS Zone Contributor' --scope $ZONE_ID"
fi

# Informational: warn if base_domain == parent_dns_zone (Liite B B29 — not
# supported by the current 00-prereqs/main.tf which tries to CREATE
# base_domain as a child zone).
if [[ -n "$BASE_DOMAIN_FROM_TF" && "$BASE_DOMAIN_FROM_TF" == "$PARENT_ZONE" ]]; then
  pf_warn "base_domain == parent_dns_zone ($PARENT_ZONE): the current terraform/00-prereqs/main.tf would try to create the parent zone again — see docs/network-prereqs.md for the 'one cluster per parent zone' pattern"
elif [[ -n "$BASE_DOMAIN_FROM_TF" && "$BASE_DOMAIN_FROM_TF" != *."$PARENT_ZONE" ]]; then
  pf_fail "base_domain ($BASE_DOMAIN_FROM_TF) is not a child sub-zone of parent_dns_zone ($PARENT_ZONE)"
  pf_info "fix: set BASE_DOMAIN to a child zone, for example ocp.$PARENT_ZONE"
fi

# B62 awareness: warn if USE_LEGACY_DNS_LAYOUT=true. The legacy layout
# (cluster zone == base_domain, records use long names like
# "api.${cluster_name}") prevents openshift-install's ingress-operator
# from finding the zone to write *.apps records, hanging the install at
# wait-for-install-complete. Default (false) is the correct setting for
# any new cluster.
USE_LEGACY="${tfvars__use_legacy_dns_layout:-${USE_LEGACY_DNS_LAYOUT:-false}}"
if [[ "$USE_LEGACY" == "true" ]]; then
  pf_warn "USE_LEGACY_DNS_LAYOUT=true: cluster install will hang at wait-for-install-complete waiting for ingress ClusterOperator; only use this for an existing pre-B62-fix cluster you cannot rebuild"
else
  pf_pass "DNS layout: new (cluster zone will be \${CLUSTER_NAME}.\${BASE_DOMAIN} with short record names — ingress-operator compatible)"
fi

return 0
