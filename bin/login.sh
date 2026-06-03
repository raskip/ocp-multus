#!/usr/bin/env bash
# Authenticate to Azure for the cluster subscription. Order of preference:
#   1. AZURE_CLIENT_ID + AZURE_CLIENT_SECRET + AZURE_TENANT_ID env vars
#      (CI / non-interactive)
#   2. ~/.azure/osServicePrincipal.json (same file the openshift-install
#      validator writes; reuses an existing install-time SP)
#   3. az login --use-device-code (interactive fallback)
#
# After login this script sets the active subscription to
# CLUSTER_SUBSCRIPTION_ID from config/cluster.env when present.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/config/cluster.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/cluster.env"
  set +a
fi

if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
  echo "[login] using env-var Service Principal"
  az login --service-principal \
    -u "$AZURE_CLIENT_ID" \
    -p "$AZURE_CLIENT_SECRET" \
    --tenant "$AZURE_TENANT_ID" \
    --only-show-errors >/dev/null
elif [[ -f "$HOME/.azure/osServicePrincipal.json" ]]; then
  echo "[login] using ~/.azure/osServicePrincipal.json"
  SP_CLIENT_ID="$(jq -r .clientId "$HOME/.azure/osServicePrincipal.json")"
  SP_CLIENT_SECRET="$(jq -r .clientSecret "$HOME/.azure/osServicePrincipal.json")"
  SP_TENANT_ID="$(jq -r .tenantId "$HOME/.azure/osServicePrincipal.json")"
  az login --service-principal \
    -u "$SP_CLIENT_ID" \
    -p "$SP_CLIENT_SECRET" \
    --tenant "$SP_TENANT_ID" \
    --only-show-errors >/dev/null
else
  echo "[login] no SP credentials; falling back to interactive device-code login"
  az login --use-device-code --only-show-errors
fi

if [[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$CLUSTER_SUBSCRIPTION_ID"
fi

az account show --query '{name:name,id:id,user:user.name}' -o table
