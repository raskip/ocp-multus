#!/usr/bin/env bash
# Cleanup script for examples/jump-host-access/A-direct-pip/.
# Runs `terraform destroy -auto-approve` against the same vars used at
# apply time. Either pass them through environment variables (same names
# as in README.md) or run `terraform destroy` manually.
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
  ${ADMIN_SSH_SOURCE_IP:+-var admin_ssh_source_ip="$ADMIN_SSH_SOURCE_IP"}
