#!/usr/bin/env bash
# 00-preflight.sh - verify az CLI is logged in, on the right subscription,
# and has the extensions required by the later scripts in this directory.
#
# This script does not modify any Azure resources.
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"

echo "==> az CLI version"
az version --query '"azure-cli"' -o tsv

echo "==> Signed-in account"
account_json=$(az account show -o json 2>/dev/null || true)
if [[ -z "$account_json" ]]; then
  echo "ERROR: not logged in. Run 'az login' or 'az login --use-device-code'." >&2
  exit 1
fi
echo "$account_json" | python3 -c '
import json, sys
a = json.load(sys.stdin)
print(f"  user:         {a.get(\"user\", {}).get(\"name\")}")
print(f"  tenantId:     {a.get(\"tenantId\")}")
print(f"  subscription: {a.get(\"name\")} ({a.get(\"id\")})")
' 2>/dev/null || echo "$account_json"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  current=$(az account show --query id -o tsv)
  if [[ "$current" != "$SUBSCRIPTION_ID" ]]; then
    echo "==> Setting subscription to $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
fi

echo "==> Required CLI extensions"
# Pre-install so later scripts never prompt interactively.
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

# No extensions are strictly required for the create-vnet/subnet/udr scripts
# in this directory, but 'azure-firewall' is needed if you also create the
# firewall policy / rule collection groups yourself.
for ext in azure-firewall; do
  if az extension show --name "$ext" >/dev/null 2>&1; then
    echo "  ok: $ext"
  else
    echo "  installing: $ext"
    az extension add --name "$ext" --only-show-errors
  fi
done

echo "==> Preflight passed."
