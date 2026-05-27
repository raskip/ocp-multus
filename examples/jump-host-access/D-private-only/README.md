# Pattern D — Private only (no public IP)

Use this pattern when your workstation can **already** reach the
spoke VNet privately — typically via:

- a site-to-site IPsec VPN that terminates in the hub,
- ExpressRoute (private peering) into the hub,
- a vWAN hub with a connected VPN gateway, or
- a Bastion/jump scenario you've built outside this repo.

In that case no public IP is created anywhere in this example. The
Terraform here is intentionally minimal: it provisions a jump VM in
the spoke with NSG rules that allow SSH only from an on-premises
CIDR (your corporate range), and an NSG that explicitly denies any
inbound from the Internet.

## What gets created

| Resource | Purpose |
|---|---|
| 1× network interface (no PIP) | Attached to the jump subnet |
| 1× NSG | `tcp/22` Allow from `onprem_cidr`; all other inbound Deny |
| 1× Linux VM | Installer host |

## Common pitfalls (verify before relying on this pattern)

- **Missing UDR back to on-prem.** If the spoke does not have a UDR
  that sends on-prem prefixes to the hub firewall / VPN GW, replies
  from the jump VM never reach you. Symptom: TCP SYN arrives at the
  VM (`tcpdump` on `eth0` shows it), but the SYN-ACK gets dropped
  somewhere on the return path.
- **Asymmetric routing across hub NVA.** If the hub uses an NVA
  (non-Microsoft firewall) and routes are not symmetric for the
  on-prem CIDR, the firewall will silently drop the return flow.
- **MTU over IPsec.** S2S VPN tunnels typically drop MTU to ~1400;
  large SSH banners or `oc` payloads can stall if anything in the
  path does not honour PMTUD. If sessions hang after `Accepted
  password`, lower MSS on your workstation's tunnel interface.
- **DNS.** `oc` must resolve `api.<cluster>.<base_domain>` to the
  internal API LB. Either link the cluster's private DNS zone to a
  DNS resolver that your workstation queries (Azure Private DNS
  Resolver in the hub is the standard pattern), or add the line to
  `/etc/hosts` on your workstation manually.

Validate reachability **before** running any `make` target:

```bash
nc -zv <jump-private-ip> 22
```

If that does not return `succeeded`, fix the connectivity story
first; nothing this Terraform creates will help.

## Apply

```bash
cd examples/jump-host-access/D-private-only
terraform init
terraform apply \
  -var "subscription_id=$CLUSTER_SUBSCRIPTION_ID" \
  -var "location=$LOCATION" \
  -var "resource_group_name=$NETWORK_RESOURCE_GROUP" \
  -var "vnet_name=$VIRTUAL_NETWORK" \
  -var "jump_subnet_name=snet-jump-installer" \
  -var "admin_ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var 'onprem_cidrs=["10.0.0.0/8"]'
```

## Cleanup

```bash
bash 99-cleanup.sh
```
