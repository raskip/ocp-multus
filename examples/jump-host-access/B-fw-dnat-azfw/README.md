# Pattern B — Hub firewall DNAT (Azure Firewall)

Routes inbound SSH (or HTTPS for API access) through an existing
**Azure Firewall** in the hub VNet to a jump VM in the spoke VNet.
No public IP on the jump host; the hub firewall already has one.

> **Azure Firewall only.** The Terraform in this directory uses the
> `azurerm_firewall_policy_rule_collection_group` resource, which is
> specific to Azure Firewall. If your hub uses Palo Alto, Fortinet,
> Check Point, or another NVA, translate the DNAT rule into your
> vendor's policy language. The *concept* is identical — the
> Terraform here just demonstrates one concrete realisation.

## What gets created

| Resource | Where |
|---|---|
| 1× DNAT rule collection in the hub firewall policy | Hub firewall policy |
| 1× UDR with default route → hub firewall private IP | Attached to the jump subnet so reply traffic does not asymmetric-route |

## Prerequisites

1. Hub VNet with Azure Firewall + firewall policy, peered to the
   spoke VNet (bidirectional, `allow_forwarded_traffic=true`).
2. A jump VM **without a public IP** already exists in the spoke
   (deploy `D-private-only/` first, or your own minimal jump VM).
3. The principal running Terraform has at least:
   - `Network Contributor` on the hub firewall policy RG, and
   - `Network Contributor` on the spoke RG (for the UDR + subnet
     association).

## Apply

```bash
cd examples/jump-host-access/B-fw-dnat-azfw
terraform init
terraform apply \
  -var "subscription_id=$CLUSTER_SUBSCRIPTION_ID" \
  -var "hub_subscription_id=$HUB_SUBSCRIPTION_ID" \
  -var "location=$LOCATION" \
  -var "hub_firewall_policy_id=/subscriptions/.../firewallPolicies/fwp-hub-001" \
  -var "hub_firewall_public_ip=A.B.C.D" \
  -var "hub_firewall_private_ip=10.100.0.4" \
  -var "spoke_resource_group=$NETWORK_RESOURCE_GROUP" \
  -var "jump_subnet_name=snet-jump-installer" \
  -var "jump_vm_private_ip=10.20.3.244" \
  -var "vnet_name=$VIRTUAL_NETWORK" \
  -var "admin_workstation_cidr=203.0.113.10/32" \
  -var "dnat_external_port=2222"
```

Then SSH:

```bash
ssh -p 2222 azureuser@A.B.C.D
```

## API access (optional)

To reach the cluster's internal API LB on port 6443 from the same
workstation, add a second NAT rule that translates
`<firewall_public_ip>:6443 → <api_lb_private_ip>:6443`. Set the
`api_lb_private_ip` variable (defaults to empty, which skips the
rule):

```bash
terraform apply ... -var "api_lb_private_ip=10.20.0.10"
```

The example also writes an `/etc/hosts` line you can copy onto your
workstation so `oc` resolves `api.<cluster>.<base_domain>` to the
firewall public IP instead of the cluster-private one.

## Cleanup

```bash
bash 99-cleanup.sh
```
