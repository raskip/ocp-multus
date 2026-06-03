#!/usr/bin/env bash
# Cleanup script for examples/jump-host-access/B-fw-dnat-azfw/.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f terraform.tfstate ]]; then
  echo "no terraform.tfstate in $(pwd); nothing to destroy"
  exit 0
fi

terraform destroy -auto-approve \
  ${CLUSTER_SUBSCRIPTION_ID:+-var subscription_id="$CLUSTER_SUBSCRIPTION_ID"} \
  ${HUB_SUBSCRIPTION_ID:+-var hub_subscription_id="$HUB_SUBSCRIPTION_ID"} \
  ${LOCATION:+-var location="$LOCATION"} \
  ${HUB_FIREWALL_POLICY_ID:+-var hub_firewall_policy_id="$HUB_FIREWALL_POLICY_ID"} \
  ${HUB_FIREWALL_PUBLIC_IP:+-var hub_firewall_public_ip="$HUB_FIREWALL_PUBLIC_IP"} \
  ${HUB_FIREWALL_PRIVATE_IP:+-var hub_firewall_private_ip="$HUB_FIREWALL_PRIVATE_IP"} \
  ${NETWORK_RESOURCE_GROUP:+-var spoke_resource_group="$NETWORK_RESOURCE_GROUP"} \
  ${VIRTUAL_NETWORK:+-var vnet_name="$VIRTUAL_NETWORK"} \
  ${JUMP_SUBNET_NAME:+-var jump_subnet_name="$JUMP_SUBNET_NAME"} \
  ${JUMP_VM_PRIVATE_IP:+-var jump_vm_private_ip="$JUMP_VM_PRIVATE_IP"} \
  ${ADMIN_WORKSTATION_CIDR:+-var admin_workstation_cidr="$ADMIN_WORKSTATION_CIDR"} \
  ${DNAT_EXTERNAL_PORT:+-var dnat_external_port="$DNAT_EXTERNAL_PORT"} \
  ${API_LB_PRIVATE_IP:+-var api_lb_private_ip="$API_LB_PRIVATE_IP"}
