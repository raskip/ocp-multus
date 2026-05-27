# Pattern A — Direct public IP on jump VM

Provisions a single Ubuntu jump VM in the spoke VNet with a public
IP. You SSH in over the public Internet (locked down to your
workstation's `/32` via NSG) and run `make` from the jump VM.

> ⚠️ **MAY NOT WORK IN ENTERPRISE TENANTS.** Many enterprise Azure
> subscriptions block `Microsoft.Network/publicIPAddresses` via
> Azure Policy, or have Defender for Cloud / MCAPS-style controls
> that silently drop inbound on internet-exposed VMs. Validate with
> your security team before deploying this pattern. If it fails,
> use pattern B (`B-fw-dnat-azfw/`) or C (`C-azure-bastion/`).

## What gets created

| Resource | Purpose |
|---|---|
| 1× public IP (Standard, Static) | Inbound SSH endpoint |
| 1× network interface | Attached to the jump subnet |
| 1× NSG with one Allow rule | `tcp/22` from `admin_ssh_source_ip` only |
| 1× Linux VM (Ubuntu 24.04 LTS, `Standard_D2s_v5`) | Installer host |

## Prerequisites

- The spoke VNet + a jump subnet (`/28` minimum) already exist. This
  example does NOT create the VNet. Use the BYO-network examples
  (`learnings/byo-network-mode`) or your own Terraform.
- A cloud-init or local SSH key pair you can paste into
  `admin_ssh_public_key`.
- Your workstation's public IP for `admin_ssh_source_ip` (e.g.
  `203.0.113.10/32`).

## Apply

```bash
cd examples/jump-host-access/A-direct-pip
terraform init
terraform apply \
  -var "subscription_id=$CLUSTER_SUBSCRIPTION_ID" \
  -var "location=$LOCATION" \
  -var "resource_group_name=$NETWORK_RESOURCE_GROUP" \
  -var "vnet_name=$VIRTUAL_NETWORK" \
  -var "jump_subnet_name=snet-jump-installer" \
  -var "admin_username=azureuser" \
  -var "admin_ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var "admin_ssh_source_ip=203.0.113.10/32"
```

Outputs the jump VM's public IP. SSH in with:

```bash
ssh azureuser@$(terraform output -raw jump_vm_public_ip)
```

## Cleanup

```bash
bash 99-cleanup.sh
```

Removes everything this example created (no manual portal clicks).
