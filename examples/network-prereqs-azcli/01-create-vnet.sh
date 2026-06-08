#!/usr/bin/env bash
# 01-create-vnet.sh - create the network resource group and the spoke VNet.
#
# Re-running is safe: az ... create is idempotent in the typical case.
set -euo pipefail

LOCATION="${LOCATION:-northeurope}"
NETWORK_RG="${NETWORK_RG:-REDACTED_RESOURCE_GROUPwork}"
VNET_NAME="${VNET_NAME:-vnet-ocp-spoke}"
VNET_CIDR="${VNET_CIDR:-10.20.0.0/21}"

echo "==> Resource group: $NETWORK_RG ($LOCATION)"
az group create \
  --name "$NETWORK_RG" \
  --location "$LOCATION" \
  --only-show-errors \
  --output none

echo "==> VNet: $VNET_NAME ($VNET_CIDR)"
az network vnet create \
  --resource-group "$NETWORK_RG" \
  --name "$VNET_NAME" \
  --address-prefixes "$VNET_CIDR" \
  --location "$LOCATION" \
  --only-show-errors \
  --output none

echo "==> Done."
echo
az network vnet show \
  --resource-group "$NETWORK_RG" \
  --name "$VNET_NAME" \
  --query '{name:name, cidr:addressSpace.addressPrefixes, location:location, id:id}' \
  -o jsonc
