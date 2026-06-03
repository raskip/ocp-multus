#!/usr/bin/env bash
# Cleanup script for examples/jump-host-access/D-private-only/.
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
  ${JUMP_SUBNET_NAME:+-var jump_subnet_name="$JUMP_SUBNET_NAME"} \
  ${ADMIN_SSH_PUBLIC_KEY:+-var admin_ssh_public_key="$ADMIN_SSH_PUBLIC_KEY"} \
  ${ONPREM_CIDRS:+-var "onprem_cidrs=$ONPREM_CIDRS"}
