#!/usr/bin/env bash
# 03-create-udr.sh - create the egress route table, default route to the
# hub firewall, and attach it to master/worker/bootstrap/multus subnets.
#
# Skip this script if your cluster is NOT behind a firewall and you are
# happy with Azure default outbound (in which case BYO-network mode is
# fine without a route table at all).
set -euo pipefail

LOCATION="${LOCATION:-northeurope}"
NETWORK_RG="${NETWORK_RG:-REDACTED_RESOURCE_GROUPwork}"
VNET_NAME="${VNET_NAME:-vnet-ocp-spoke}"
ROUTE_TABLE_NAME="${ROUTE_TABLE_NAME:-rt-ocp-egress}"
HUB_FW_PRIVATE_IP="${HUB_FW_PRIVATE_IP:?Set HUB_FW_PRIVATE_IP to the private IP of your hub firewall NVA}"

# Subnets that should egress via the firewall. SR-IOV subnet is intentionally
# omitted - SR-IOV often bypasses the standard CNI and may not need the UDR.
SUBNETS="${SUBNETS:-snet-ocp-master snet-ocp-bootstrap snet-ocp-worker snet-ocp-multus}"

echo "==> Route table: $ROUTE_TABLE_NAME"
az network route-table create \
  --resource-group "$NETWORK_RG" \
  --name "$ROUTE_TABLE_NAME" \
  --location "$LOCATION" \
  --disable-bgp-route-propagation false \
  --only-show-errors \
  --output none

echo "==> Default route: 0.0.0.0/0 -> VirtualAppliance $HUB_FW_PRIVATE_IP"
az network route-table route create \
  --resource-group "$NETWORK_RG" \
  --route-table-name "$ROUTE_TABLE_NAME" \
  --name default-egress-fw \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$HUB_FW_PRIVATE_IP" \
  --only-show-errors \
  --output none

for sn in $SUBNETS; do
  echo "==> Attach route table to subnet: $sn"
  az network vnet subnet update \
    --resource-group "$NETWORK_RG" \
    --vnet-name "$VNET_NAME" \
    --name "$sn" \
    --route-table "$ROUTE_TABLE_NAME" \
    --only-show-errors \
    --output none
done

echo
ROUTE_TABLE_ID=$(az network route-table show -g "$NETWORK_RG" -n "$ROUTE_TABLE_NAME" --query id -o tsv)
echo "==> Route table ID (paste into terraform/01-network/terraform.tfvars):"
echo "  route_table_id = $ROUTE_TABLE_ID"
