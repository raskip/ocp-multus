#!/usr/bin/env bash
# 99-cleanup.sh - tear down everything 01/02/03 created by deleting the
# network resource group.
#
# WARNING: this deletes the entire NETWORK_RG, including ANYTHING ELSE
# in it. Verify the RG name and contents before confirming.
set -euo pipefail

NETWORK_RG="${NETWORK_RG:-REDACTED_RESOURCE_GROUPwork}"
ASSUME_YES="${ASSUME_YES:-0}"

if ! az group show -n "$NETWORK_RG" >/dev/null 2>&1; then
  echo "==> Resource group '$NETWORK_RG' not found - nothing to do."
  exit 0
fi

echo "==> Resources in $NETWORK_RG:"
az resource list -g "$NETWORK_RG" --query '[].{name:name, type:type}' -o table

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "Delete resource group '$NETWORK_RG' AND EVERYTHING IN IT? (yes/no) " ans
  if [[ "$ans" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "==> Deleting $NETWORK_RG ..."
az group delete --name "$NETWORK_RG" --yes --no-wait
echo "==> Deletion queued (running in background)."
