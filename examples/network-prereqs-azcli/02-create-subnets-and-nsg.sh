#!/usr/bin/env bash
# 02-create-subnets-and-nsg.sh - create the 5 OpenShift subnets and the
# master + worker NSGs (with the minimum rules from docs/network-prereqs.md).
#
# Subnets are NOT given a route table here - that is done by
# 03-create-udr.sh. The cluster install team will populate
# terraform/01-network/terraform.tfvars with the subnet IDs printed at the
# end of this script.
set -euo pipefail

LOCATION="${LOCATION:-northeurope}"
NETWORK_RG="${NETWORK_RG:-REDACTED_RESOURCE_GROUPwork}"
VNET_NAME="${VNET_NAME:-vnet-ocp-spoke}"

SUBNET_MASTER_CIDR="${SUBNET_MASTER_CIDR:-10.20.0.0/27}"
SUBNET_BOOTSTRAP_CIDR="${SUBNET_BOOTSTRAP_CIDR:-10.20.0.32/28}"
SUBNET_WORKER_CIDR="${SUBNET_WORKER_CIDR:-10.20.1.0/24}"
SUBNET_MULTUS_CIDR="${SUBNET_MULTUS_CIDR:-10.20.2.0/24}"
SUBNET_SRIOV_CIDR="${SUBNET_SRIOV_CIDR:-10.20.3.0/27}"

NSG_MASTER="${NSG_MASTER:-nsg-ocp-master}"
NSG_WORKER="${NSG_WORKER:-nsg-ocp-worker}"

create_nsg() {
  local name=$1
  echo "==> NSG: $name"
  az network nsg create \
    --resource-group "$NETWORK_RG" \
    --name "$name" \
    --location "$LOCATION" \
    --only-show-errors \
    --output none
}

create_rule() {
  local nsg=$1 name=$2 prio=$3 ports=$4 desc=$5
  az network nsg rule create \
    --resource-group "$NETWORK_RG" \
    --nsg-name "$nsg" \
    --name "$name" \
    --priority "$prio" \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-address-prefixes VirtualNetwork \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges $ports \
    --description "$desc" \
    --only-show-errors \
    --output none
}

create_lb_rule() {
  local nsg=$1
  az network nsg rule create \
    --resource-group "$NETWORK_RG" \
    --nsg-name "$nsg" \
    --name allow-azure-lb \
    --priority 4000 \
    --direction Inbound \
    --access Allow \
    --protocol '*' \
    --source-address-prefixes AzureLoadBalancer \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --description "Allow Azure LB health probes" \
    --only-show-errors \
    --output none
}

create_nsg "$NSG_MASTER"
create_rule "$NSG_MASTER" allow-api          100 6443  "Cluster API"
create_rule "$NSG_MASTER" allow-mcs          110 22623 "Machine Config Server"
create_rule "$NSG_MASTER" allow-ssh          120 22    "SSH from VNet"
create_rule "$NSG_MASTER" allow-control      130 "9000-9999"   "etcd, controller-manager, scheduler"
create_rule "$NSG_MASTER" allow-kubelet      140 "10250-10259" "kubelet, etcd-events"
create_lb_rule "$NSG_MASTER"

create_nsg "$NSG_WORKER"
create_rule "$NSG_WORKER" allow-http         100 80    "Apps HTTP ingress"
create_rule "$NSG_WORKER" allow-https        110 443   "Apps HTTPS ingress"
create_rule "$NSG_WORKER" allow-ssh          120 22    "SSH from VNet"
create_rule "$NSG_WORKER" allow-kubelet      130 "10250-10259" "kubelet"
create_rule "$NSG_WORKER" allow-nodeport     140 "30000-32767" "NodePort (if used)"
create_lb_rule "$NSG_WORKER"

create_subnet() {
  local name=$1 cidr=$2 nsg=$3
  echo "==> Subnet: $name ($cidr)"
  if [[ -n "$nsg" ]]; then
    az network vnet subnet create \
      --resource-group "$NETWORK_RG" \
      --vnet-name "$VNET_NAME" \
      --name "$name" \
      --address-prefixes "$cidr" \
      --network-security-group "$nsg" \
      --only-show-errors \
      --output none
  else
    az network vnet subnet create \
      --resource-group "$NETWORK_RG" \
      --vnet-name "$VNET_NAME" \
      --name "$name" \
      --address-prefixes "$cidr" \
      --only-show-errors \
      --output none
  fi
}

create_subnet snet-ocp-master    "$SUBNET_MASTER_CIDR"    "$NSG_MASTER"
create_subnet snet-ocp-bootstrap "$SUBNET_BOOTSTRAP_CIDR" "$NSG_WORKER"
create_subnet snet-ocp-worker    "$SUBNET_WORKER_CIDR"    "$NSG_WORKER"
create_subnet snet-ocp-multus    "$SUBNET_MULTUS_CIDR"    "$NSG_WORKER"
create_subnet snet-ocp-sriov     "$SUBNET_SRIOV_CIDR"     "$NSG_WORKER"

echo
echo "==> Subnet IDs (paste into terraform/01-network/terraform.tfvars):"
for sn in snet-ocp-master snet-ocp-bootstrap snet-ocp-worker snet-ocp-multus snet-ocp-sriov; do
  id=$(az network vnet subnet show -g "$NETWORK_RG" --vnet-name "$VNET_NAME" -n "$sn" --query id -o tsv)
  printf '  %-22s = %s\n' "${sn//-/_}_id" "$id"
done
