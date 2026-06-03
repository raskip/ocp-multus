# BYO-network: Azure CLI reference scripts

This directory contains runnable reference scripts that the **network
team** can use (or adapt) to create the Azure networking prerequisites
for an OpenShift Azure UPI cluster in BYO-network mode. They are
deliberately simple — `bash` + `az` CLI and PowerShell + `az` CLI —
so you can read them top to bottom and translate them to whichever
IaC tool your organization standardizes on (Terraform, Bicep, ARM,
Ansible, Pulumi).

For the full requirements (sizing, NSG rules, UDR contract, DNS,
peering) see [`docs/network-prereqs.md`](../../docs/network-prereqs.md).

## Files

| Script | Purpose |
|---|---|
| `00-preflight.{sh,ps1}` | Verify `az` is logged in, the right subscription is selected, required extensions are installed |
| `01-create-vnet.{sh,ps1}` | Create the network RG and the spoke VNet |
| `02-create-subnets-and-nsg.{sh,ps1}` | Create the 5 subnets, master and worker NSGs with the minimum rules from `docs/network-prereqs.md` |
| `03-create-udr.{sh,ps1}` | Create the route table, add the `0.0.0.0/0 → <hub-fw>` default route, and attach it to master/worker/bootstrap/multus subnets |
| `99-cleanup.{sh,ps1}` | Tear down everything created above (deletes the RG — use with care) |

All scripts read configuration from environment variables. See the
top of each script for the variables it expects. Defaults make the
scripts runnable against an empty subscription, but you must override
at minimum:

- `SUBSCRIPTION_ID`
- `LOCATION`
- `NETWORK_RG`
- `VNET_NAME`
- `VNET_CIDR`
- `HUB_FW_PRIVATE_IP` (for `03-create-udr`)

## Order

```
00-preflight  ->  01-create-vnet  ->  02-create-subnets-and-nsg  ->  03-create-udr
```

After step 3, the network team's job is done. Hand off the subnet
and route-table Resource IDs to the cluster install team (see section
8 of `docs/network-prereqs.md`). They will populate
`terraform/01-network/terraform.tfvars` with
`manage_network_resources = false` and the IDs.

## Idempotency

Every `az` `create` here uses `--only-show-errors`. Re-running a
script will either no-op or report an existing-resource error you can
safely ignore. The scripts are not transactional - if one step fails,
fix the underlying issue and re-run from that step.

## Peering

These scripts do **not** create VNet peerings or DNS zones - those
are usually owned by a central connectivity / DNS team. The
requirements are documented in sections 5 (DNS) and 6 (Peering) of
`docs/network-prereqs.md`. Add your own scripts or open tickets with
your connectivity team to satisfy them.
