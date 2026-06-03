#!/usr/bin/env bash
# scripts/preflight/08-fw-policy.sh
#
# Verify the Azure Firewall policy that governs spoke egress exists and
# (optionally) contains a rule collection group permitting the spoke
# CIDR. Only relevant when egress goes through Azure Firewall.
#
# This check is opt-in: we look for FW_POLICY_ID / FW_POLICY_NAME +
# FW_POLICY_RESOURCE_GROUP env vars (or terraform/01-network tfvars).
# If unset we SKIP — the check is informational, not blocking, since
# the firewall may be third-party / Palo Alto / Fortinet etc.
#
# Read-only.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "08: Azure Firewall policy (optional)"

pf_load_config || return 0
pf_require_cmd az "" || return 0

# Allow the operator to set these in their environment / shell before
# running preflight. Repo-managed mode does not own the firewall, so we
# don't read them from terraform/*/terraform.tfvars by default.
POLICY_NAME="${FW_POLICY_NAME:-}"
POLICY_RG="${FW_POLICY_RESOURCE_GROUP:-}"
POLICY_SUB="${FW_POLICY_SUBSCRIPTION_ID:-${HUB_SUBSCRIPTION_ID:-${CLUSTER_SUBSCRIPTION_ID:-}}}"

if [[ -z "$POLICY_NAME" || -z "$POLICY_RG" ]]; then
  pf_skip "FW_POLICY_NAME / FW_POLICY_RESOURCE_GROUP not set — skipping Azure Firewall policy check"
  pf_info "If your egress goes through Azure Firewall, export FW_POLICY_NAME / FW_POLICY_RESOURCE_GROUP / FW_POLICY_SUBSCRIPTION_ID and re-run."
  pf_info "If your egress goes through a third-party NVA (Palo Alto / Fortinet / Checkpoint), confirm the required outbound destinations are allowed — see docs/required-outbound-destinations.md."
  return 0
fi

SUB_ARGS=()
[[ -n "$POLICY_SUB" ]] && SUB_ARGS=(--subscription "$POLICY_SUB")

POL_JSON=$(az network firewall policy show \
  -g "$POLICY_RG" -n "$POLICY_NAME" "${SUB_ARGS[@]}" -o json 2>/dev/null || true)

if [[ -z "$POL_JSON" ]]; then
  pf_fail "firewall policy $POLICY_NAME not found in RG $POLICY_RG (sub: ${POLICY_SUB:-<current>})"
  pf_info "fix: verify FW_POLICY_NAME / FW_POLICY_RESOURCE_GROUP / FW_POLICY_SUBSCRIPTION_ID"
  return 0
fi
pf_pass "firewall policy $POLICY_NAME exists in $POLICY_RG"

# Best-effort: list rule collection groups; warn if there are none.
RCG_COUNT=$(az network firewall policy rule-collection-group list \
  -g "$POLICY_RG" --policy-name "$POLICY_NAME" "${SUB_ARGS[@]}" \
  --query 'length(@)' -o tsv 2>/dev/null || echo 0)
if [[ "$RCG_COUNT" -eq 0 ]]; then
  pf_warn "policy $POLICY_NAME has zero rule collection groups — egress will be implicitly denied by Azure FW default rule"
  pf_info "fix: add a rule collection group permitting at minimum the cluster's outbound destinations (see docs/required-outbound-destinations.md)"
else
  pf_pass "policy $POLICY_NAME has $RCG_COUNT rule collection group(s)"
fi

return 0
