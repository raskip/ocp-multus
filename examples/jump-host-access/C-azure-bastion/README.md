# Pattern C — Azure Bastion (optional enterprise access pattern)

The main repo install does **not** deploy Azure Bastion. Use this
separate example only when you explicitly choose Bastion as the access
pattern for a private cluster. No public IP is needed on the jump VM, no
DNAT, no firewall rules. You tunnel through the Bastion host from your
workstation using `az network bastion ssh` or `az network bastion
tunnel`.

This is often a good fit for enterprise tenants where
`Microsoft.Network/publicIPAddresses` is restricted by policy: Azure
Bastion is *expected* to have a public IP (it is a managed service)
and most tenant policies whitelist it explicitly.

This example is also code-level opt-in: Terraform creates **nothing**
unless you pass `-var "create_bastion=true"`.

## What gets created

| Resource | Purpose |
|---|---|
| `AzureBastionSubnet` (`/26` minimum) | Required name for Bastion |
| 1× public IP (Standard, Static) | Required by Bastion |
| 1× Azure Bastion host (Standard SKU) | The actual managed gateway |

**Cost:** ~$140/mo for Standard SKU (always-on; not deallocatable).

## Prerequisites

1. Spoke VNet exists and has at least a `/26` of free address space
   for the Bastion subnet.
2. A jump VM **without a public IP** exists in the spoke (deploy
   `D-private-only/` first or your own minimal jump VM).
3. Your workstation has Azure CLI ≥ 2.50 with the `bastion`
   extension: `az extension add --name bastion`.

## Apply

```bash
cd examples/jump-host-access/C-azure-bastion
terraform init
terraform apply \
  -var "create_bastion=true" \
  -var "subscription_id=$CLUSTER_SUBSCRIPTION_ID" \
  -var "location=$LOCATION" \
  -var "resource_group_name=$NETWORK_RESOURCE_GROUP" \
  -var "vnet_name=$VIRTUAL_NETWORK" \
  -var "bastion_subnet_cidr=10.20.4.0/26"
```

## Use

SSH into the jump VM through Bastion:

```bash
az network bastion ssh \
  --name bastion-installer \
  --resource-group $NETWORK_RESOURCE_GROUP \
  --target-resource-id $(az vm show --resource-group $NETWORK_RESOURCE_GROUP \
                                     --name vm-jump-installer --query id -o tsv) \
  --auth-type ssh-key \
  --username azureuser \
  --ssh-key ~/.ssh/id_ed25519
```

Tunnel TCP for `oc` (so `oc` running on your workstation reaches the
cluster API LB through Bastion → jump VM → spoke routing):

```bash
az network bastion tunnel \
  --name bastion-installer \
  --resource-group $NETWORK_RESOURCE_GROUP \
  --target-resource-id $(az vm show --resource-group $NETWORK_RESOURCE_GROUP \
                                     --name vm-jump-installer --query id -o tsv) \
  --resource-port 6443 \
  --port 6443
```

Then on your workstation add `127.0.0.1 api.<cluster>.<base_domain>`
to `/etc/hosts` and run `oc` normally.

## Cleanup

```bash
bash 99-cleanup.sh
```
