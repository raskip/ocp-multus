#!/usr/bin/env bash
# Cleanup script for examples/jump-host-access/C-azure-bastion/.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f terraform.tfstate ]]; then
  echo "no terraform.tfstate in $(pwd); nothing to destroy"
  exit 0
fi

terraform destroy -auto-approve \
  ${CLUSTER_SUBSCRIPTION_ID:+-var subscription_id="$CLUSTER_SUBSCRIPTION_ID"} \
  ${LOCATION:+-var location="$LOCATION"} \
  ${NETWORK_RESOURCE_GROUP:+-var resource_group_name="$NETWORK_RESOURCE_GROUP"} \
  ${VIRTUAL_NETWORK:+-var vnet_name="$VIRTUAL_NETWORK"} \
  ${BASTION_SUBNET_CIDR:+-var bastion_subnet_cidr="$BASTION_SUBNET_CIDR"}
