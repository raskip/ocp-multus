#!/usr/bin/env bash
# scripts/preflight/09-sp-json.sh
#
# Verify ~/.azure/osServicePrincipal.json exists, has the four required
# fields, and is mode 600 — openshift-install reads this file at
# `create manifests` / `create ignition` time and the lifecycle scripts
# (cluster-shutdown/startup/etcd-backup) fall back to it when az MSAL
# cache is missing (typical in WSL2 + non-interactive shells).
#
# Read-only — never prints the secret value.

set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf_section "09: Service Principal JSON (~/.azure/osServicePrincipal.json)"

pf_require_cmd jq "" || return 0

SP_JSON="${AZURE_AUTH_LOCATION:-$HOME/.azure/osServicePrincipal.json}"

if [[ ! -f "$SP_JSON" ]]; then
  pf_fail "$SP_JSON not found"
  pf_info "fix: create a Service Principal and write its credentials:"
  pf_info "     az ad sp create-for-rbac --name ocp-installer-\$CLUSTER_NAME --role Reader --scopes /subscriptions/<sub>"
  pf_info "     install -m 600 /dev/stdin $SP_JSON <<EOF"
  pf_info '       {"clientId":"...", "clientSecret":"...", "tenantId":"...", "subscriptionId":"..."}'
  pf_info "     EOF"
  pf_info "see docs/azure-credentials.md for the full walkthrough"
  return 0
fi

if ! jq -e '. as $j | (["clientId","clientSecret","tenantId","subscriptionId"] - ($j|keys)) | length == 0' "$SP_JSON" >/dev/null 2>&1; then
  pf_fail "$SP_JSON is missing one or more required keys (clientId / clientSecret / tenantId / subscriptionId)"
  pf_info "fix: regenerate the file with all four keys"
  return 0
fi
pf_pass "$SP_JSON has clientId / clientSecret / tenantId / subscriptionId"

# Permissions: 600 (Unix). On Windows / WSL2 NTFS-mount, stat reports
# 777 for everything — skip the check rather than print a misleading
# WARN.
if stat -c '%n' . >/dev/null 2>&1; then
  perms=$(stat -c '%a' "$SP_JSON" 2>/dev/null || echo "?")
else
  perms=$(stat -f '%Mp%Lp' "$SP_JSON" 2>/dev/null || echo "?")
fi
case "$SP_JSON" in
  /mnt/c/*|/mnt/d/*)
    pf_skip "permission check skipped: $SP_JSON is on a WSL2 /mnt/* DrvFs mount (always reports 777)"
    ;;
  *)
    if [[ "$perms" == "600" || "$perms" == "400" ]]; then
      pf_pass "$SP_JSON permissions are $perms"
    elif [[ "$perms" == "?" ]]; then
      pf_skip "could not stat $SP_JSON permissions"
    else
      pf_warn "$SP_JSON permissions are $perms (recommend 600)"
      pf_info "fix: chmod 600 $SP_JSON"
    fi
    ;;
esac

# Best-effort: does the subscriptionId in the JSON match CLUSTER_SUBSCRIPTION_ID?
pf_load_config || return 0
if [[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]]; then
  json_sub=$(jq -r '.subscriptionId' "$SP_JSON")
  if [[ "$json_sub" != "$CLUSTER_SUBSCRIPTION_ID" ]]; then
    pf_warn "$SP_JSON subscriptionId ($json_sub) does not match CLUSTER_SUBSCRIPTION_ID ($CLUSTER_SUBSCRIPTION_ID)"
    pf_info "fix: regenerate the SP JSON pointing at the cluster subscription, or update config/cluster.env"
  else
    pf_pass "$SP_JSON subscriptionId matches CLUSTER_SUBSCRIPTION_ID"
  fi
fi

return 0
