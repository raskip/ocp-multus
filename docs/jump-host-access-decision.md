# Jump-host access decision tree

`publish: Internal` is the default in this repo because production
OpenShift clusters on Azure almost always sit behind an internal API
load balancer. That means the installer host (where you run
`terraform`, `openshift-install`, and `oc`) needs a way to reach the
spoke VNet that does **not** rely on the cluster API being exposed
to the public Internet.

There are four patterns we have seen work in practice. Pick one with
your security team before `make prereqs`, then copy the matching
example from `examples/jump-host-access/` into your repo fork.

## Quick decision tree

```
                  Can the installer host already reach the spoke VNet
                  privately (corporate VPN / ExpressRoute / vWAN)?
                              │
                  ┌───────────┴───────────┐
                  │                       │
                yes                       no
                  │                       │
                  ▼                       ▼
        D. Private-only          Are public IPs on jump VMs allowed
        (no jump VM in           by the cluster subscription's policy?
         spoke required)                  │
                              ┌───────────┴───────────┐
                              │                       │
                            yes                       no
                              │                       │
                              ▼                       ▼
                    A. Direct PIP        Is there a centralised hub
                    on jump VM           firewall the spoke peers with?
                                                     │
                                       ┌─────────────┴─────────────┐
                                       │                           │
                                     yes                           no
                                       │                           │
                                       ▼                           ▼
                              B. Hub-FW DNAT             C. Azure Bastion
                              (firewall vendor-specific)
```

## Pattern comparison

| Pattern | Public IP on jump host | Extra Azure cost | Tenant-policy friendly | Setup complexity | Repo example |
|---|---|---|---|---|---|
| **A. Direct PIP** | yes | ~$3/mo per PIP | ❌ Frequently blocked by enterprise policy | low | `examples/jump-host-access/A-direct-pip/` |
| **B. Hub-FW DNAT** | no (on the jump host itself; hub firewall already has one) | – (uses existing firewall) | ✅ usually accepted because security team controls the rules | medium — needs DNAT rule + UDR | `examples/jump-host-access/B-fw-dnat-azfw/` (Azure Firewall only) |
| **C. Azure Bastion** | no | ~$140/mo (Standard SKU) plus AzureBastionSubnet /26 | ✅✅ designed for this | low | `examples/jump-host-access/C-azure-bastion/` |
| **D. Private-only** | no | – | ✅✅ production realistic | depends entirely on existing WAN | `examples/jump-host-access/D-private-only/` |

## How to choose

1. **If your workstation already has private connectivity to the
   spoke VNet (ExpressRoute, S2S VPN, vWAN), use D.** No jump host is
   needed at all and there is nothing public-facing to attack.

2. **If you do not have private connectivity, but your security team
   permits public IPs on jump VMs, use A.** It is the simplest setup,
   but expect pushback in production tenants. Many enterprise
   subscriptions have an Azure Policy that denies
   `Microsoft.Network/publicIPAddresses` or applies a deny-all NSG to
   any subnet that hosts a public IP.

3. **If a centralised hub firewall already terminates north-south
   traffic, use B.** This is the cleanest fit for spoke-and-hub
   topologies because the security team already operates the
   firewall. The downside is that the DNAT rule is *vendor specific*
   (Azure Firewall, Palo Alto, Fortinet, Check Point, …); the
   `examples/jump-host-access/B-fw-dnat-azfw/` snippet covers Azure
   Firewall only. For other vendors translate the rule into your
   vendor's syntax.

4. **If none of the above apply, use C.** Azure Bastion deploys into
   the spoke VNet directly, requires no public IP on the jump VM, and
   integrates with `az network bastion tunnel` for SSH and
   `kubectl/oc` reachability. The price (~$140/mo Standard SKU) is
   usually a fair trade-off for the simplicity.

## What "use this pattern" actually means

Patterns A, B, and C all require **a jump VM inside the spoke VNet**
that you SSH into and run `make` from. Pattern D assumes your
workstation is *itself* on a network that can reach the spoke
privately, so the installer host is your workstation and no jump VM
is needed.

In every case:

- `make wait-bootstrap` and `make wait-install` need TCP reach to the
  internal API LB on port 6443.
- `oc` from the same installer host must be able to resolve and reach
  `api.<cluster>.<base_domain>` (private DNS zone, linked to the spoke
  VNet) and `*.apps.<cluster>.<base_domain>` once apps are deployed.
- The storage account that holds RHCOS + ignition files is reachable
  only via a private endpoint — pattern A/B/C/D does not affect this
  because the uploader VM (deployed by `make network`) brokers the
  upload server-side.

## Cleanup

Each example directory has a `99-cleanup.sh` (or `.ps1`) that removes
the pattern-specific resources. Run it after `make destroy` to leave
no orphans:

```bash
bash examples/jump-host-access/<pattern>/99-cleanup.sh
```

## See also

- `docs/installer-host-requirements.md` — what the installer host
  needs in terms of reach + RBAC + filesystem state.
- `docs/network-prereqs.md` — VNet / subnet / NSG prerequisites
  (added by `learnings/byo-network-mode`).
- `DEMO.md` — full per-target runbook.
