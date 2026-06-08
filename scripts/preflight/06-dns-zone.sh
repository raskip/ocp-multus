#!/usr/bin/env bash
# scripts/preflight/06-dns-zone.sh
#
# Verify the parent DNS zone exists and that the current identity has
# both permissions required by terraform/00-prereqs:
#   1. DNS RG-scope rights to create/manage the child public zone
#      (base_domain).
#   2. parent-zone rights to write the NS delegation record.
# May live in a different subscription (dns_subscription_id) — we handle
# that via --subscription flags.
#
# Read-only — only `az network dns zone show` and a role-assignment
# probe. Does not create or modify any record.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "06: public DNS zone + delegation permissions"

pf_load_config || return 0
pf_require_cmd az "" || return 0
pf_require_cmd jq "" || return 0

pf_load_tfvars 00-prereqs || true

# Public DNS is opt-in. When create_public_dns is false (default), the repo
# provisions NO public zone or NS delegation, so the parent-zone existence and
# write-permission probes below do not apply. The cluster's api / api-int /
# *.apps records are served by the private DNS zone instead.
CREATE_PUBLIC_DNS_EFF="${tfvars__create_public_dns:-${CREATE_PUBLIC_DNS:-false}}"
if [[ "$CREATE_PUBLIC_DNS_EFF" != "true" ]]; then
  pf_pass "public DNS disabled (CREATE_PUBLIC_DNS=false) — internal-only, no public sub-zone or NS delegation to verify"
  pf_info "note: install-config still sets baseDomainResourceGroupName; the OpenShift Azure installer may validate a public base-domain zone there. See docs/dns-internal-only.md"
  return 0
fi

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

PRINCIPAL_ID=""
if [[ -n "${AZURE_AUTH_LOCATION:-}" ]]; then
  SP_JSON="$AZURE_AUTH_LOCATION"
elif [[ -n "${AZURE_SP_JSON:-}" ]]; then
  SP_JSON="$AZURE_SP_JSON"
elif [[ -n "${AZURE_CONFIG_DIR:-}" ]]; then
  SP_JSON="$AZURE_CONFIG_DIR/osServicePrincipal.json"
else
  SP_JSON="$HOME/.azure/osServicePrincipal.json"
fi
if [[ -f "$SP_JSON" ]]; then
  CLIENT_ID=$(jq -r '.clientId // empty' "$SP_JSON" 2>/dev/null || true)
  if [[ -n "$CLIENT_ID" ]]; then
    PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)
  fi
fi
if [[ -z "$PRINCIPAL_ID" ]]; then
  ACCOUNT_USER=$(az account show --query user.name -o tsv 2>/dev/null || true)
  ACCOUNT_TYPE=$(az account show --query user.type -o tsv 2>/dev/null || true)
  if [[ "$ACCOUNT_TYPE" == "servicePrincipal" && -n "$ACCOUNT_USER" ]]; then
    PRINCIPAL_ID=$(az ad sp show --id "$ACCOUNT_USER" --query id -o tsv 2>/dev/null || true)
  fi
fi
[[ -z "$PRINCIPAL_ID" ]] && PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

if [[ -z "$PRINCIPAL_ID" ]]; then
  pf_warn "cannot resolve principal id; skipping DNS write-permission probe"
  return 0
fi

DNS_SUB_EFFECTIVE="${DNS_SUB:-$(az account show --query id -o tsv 2>/dev/null || true)}"
RG_SCOPE="/subscriptions/${DNS_SUB_EFFECTIVE}/resourceGroups/$PARENT_RG"

has_dns_role() {
  local scope="$1"
  az role assignment list --assignee "$PRINCIPAL_ID" --scope "$scope" --include-inherited -o json 2>/dev/null \
    | jq -r 'any(.[]; .roleDefinitionName | IN("DNS Zone Contributor", "Contributor", "Owner"))'
}

# Terraform creates and tags the child public zone ${BASE_DOMAIN} in this
# resource group. Parent-zone scoped DNS rights alone are not enough.
RG_WRITE_OK=$(has_dns_role "$RG_SCOPE")
if [[ "$RG_WRITE_OK" == "true" ]]; then
  pf_pass "current identity can manage public child DNS zones in RG $PARENT_RG"
else
  pf_fail "current identity has no DNS Zone Contributor / Contributor / Owner on DNS resource group $PARENT_RG"
  pf_info "why: terraform/00-prereqs creates/tags child public zone ${BASE_DOMAIN_FROM_TF:-<base_domain>} in this RG; parent-zone scoped rights alone are not enough"
  pf_info "fix: az role assignment create --assignee $PRINCIPAL_ID --role 'DNS Zone Contributor' --scope $RG_SCOPE"
fi

ZONE_WRITE_OK=$(has_dns_role "$ZONE_ID")
if [[ "$ZONE_WRITE_OK" != "true" && "$RG_WRITE_OK" == "true" ]]; then
  ZONE_WRITE_OK="true"
fi

if [[ "$ZONE_WRITE_OK" == "true" ]]; then
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
