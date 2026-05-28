# Pre-install procurement checklist

This page lists every external dependency you have to gather **before
you clone the repo**. Most items can be requested in parallel by
different teams, so start the long-lead ones first. The repo's
own checks (`make verify`, `make preflight`) cannot help with any
of this — they only run after you already have the artefacts below
on disk and the cloud-side resources in place.

> **Use this page as a forwardable checklist.** Hand the relevant
> rows to your DNS team, your Entra admin, your network-security team,
> and your subscription owner. Each row has its own "How to get" and
> "Reference doc" so the recipient can act without reading the rest of
> the repo.

## Lead-time picture

```
Item                              greenfield (1 person, 1 sub)        enterprise (5 teams)
──────────────────────────────────────────────────────────────────────────────────────────
Red Hat developer account         | 5 min                            | 5 min (often pre-existing)
Red Hat pull secret               | 5 min                            | 5 min
Azure subscription + owner role   | already yours                    | days–weeks (subscription vending)
D-series vCPU quota ≥ 46          | minutes (self-service)           | 1–3 days (Azure support ticket)
Service Principal + role assigns  | 5 min (`az ad sp create-for-rbac`)| days–weeks (Entra approval)
Public DNS parent zone + delegate | minutes (if you own the zone)    | 1–2 weeks (DNS team ticket)
VNet + subnet allocation          | n/a (Terraform creates)          | 1–2 weeks (network team ticket)
UDR / firewall outbound allowlist | minutes (Azure Firewall lab)     | 1–2 weeks (security team)
Proxy CA bundle (if TLS-inspect)  | n/a                              | days (security team)
Image-registry storage decision   | minutes                          | days (security team review)
Jump-host access pattern          | minutes (A direct PIP)           | days (B/C/D + change ticket)
Source IP (`ADMIN_SSH_SOURCE_IP`) | `curl ifconfig.me`               | ask IT for VPN exit CIDR
OpenShift version pin             | minutes (pick `stable-4.18`)     | days (security approves channel)
Subscription IDs (1–3 different)  | minutes (`az account list`)      | minutes (often need to ask 3 owners)
Cost approval (~$500–800/mo)      | self-approve                     | finance / business case
```

Greenfield total: **1–2 hours**. Enterprise total: **1–2 weeks** with
overlap, **4–6 weeks** if items have to go sequentially.

## The checklist

| # | Item | Owner role | Lead time | How to get | Reference |
|---|---|---|---|---|---|
| 1 | Red Hat developer account | self | 5 min | Sign up at <https://developers.redhat.com/register> (free) | — |
| 2 | Red Hat pull secret | self | 5 min | Logged in at <https://console.redhat.com/openshift/install/pull-secret> → save as `secrets/pull-secret.txt` | [`quickstart.md` §2](./quickstart.md) |
| 3 | Azure subscription with Owner or Contributor | subscription owner | days–weeks | Through your cloud governance process. PoC works fine in a sandbox sub. | — |
| 4 | D-series vCPU quota ≥ 46 in target region | Azure support | 1–3 days | `az vm list-usage -l <region> -o table` → file a quota-increase ticket if `standardDSv5Family` `currentValue + 46 > limit` | [`preflight-checklist.md` §5](./preflight-checklist.md) |
| 5 | Service Principal (E1–E5 pattern) | Entra admin | days–weeks | `az ad sp create-for-rbac --name ocp-installer --years 1 --skip-assignment` then add Contributor on workload RG + Network Contributor on VNet RG. Save JSON to `~/.azure/osServicePrincipal.json` with chmod 600. | [`azure-credentials.md`](./azure-credentials.md), [`azure-identity-options.md`](./azure-identity-options.md) |
| 6 | Public parent DNS zone + write access | DNS team | 1–2 weeks | The repo creates a sub-zone (`${BASE_DOMAIN}` under `${PARENT_DNS_ZONE}`) and writes one NS-record into the parent. Your SP needs **DNS Zone Contributor** on the parent zone's resource group. | [`network-prereqs.md` §5](./network-prereqs.md) |
| 7 | VNet (only if BYO-network) | network team | 1–2 weeks | Subnet sizing: control plane /27, workers /24, bootstrap /27, Multus /24, SR-IOV-style /24, jump /28. NSGs allow intra-cluster traffic. Hand them [`docs/network-prereqs.md`](./network-prereqs.md). | [`network-prereqs.md`](./network-prereqs.md), [`examples/network-prereqs-azcli/`](../examples/network-prereqs-azcli/) |
| 8 | Outbound destinations allowed through your firewall / NVA | network-security team | 1–2 weeks | Vendor-neutral FQDN/IP/port list to add to your Palo Alto / Fortinet / Checkpoint / Azure Firewall rule base | [`required-outbound-destinations.md`](./required-outbound-destinations.md) |
| 9 | Proxy CA bundle (only if TLS-inspecting proxy) | security team | days | Get the proxy's signing CA in PEM form. The repo injects it as `additionalTrustBundle` into `install-config.yaml`. | [`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md) |
| 10 | Image-registry storage decision | security team | days | Tenants that block `allowSharedKeyAccess` cannot use the default registry storage. Pick: (A) `Removed` mode, (B) Entra-ID auth on a pre-created storage account, (C) emptyDir for PoC. | [`image-registry-options.md`](./image-registry-options.md) |
| 11 | Jump-host access pattern (A/B/C/D) | network-security team | days | Decide before `make prereqs`. A = direct PIP (often blocked), B = hub-FW DNAT, C = Azure Bastion, D = private-only via VPN/ExpressRoute. | [`jump-host-access-decision.md`](./jump-host-access-decision.md), [`installer-host-requirements.md`](./installer-host-requirements.md) |
| 12 | `ADMIN_SSH_SOURCE_IP` (your egress IP / VPN exit CIDR) | self or IT | minutes | `curl ifconfig.me` for personal, or ask IT for the corporate VPN exit CIDR. Used in NSG inbound rule on the uploader/jump VM. | [`config/cluster.example.env` line 55](../config/cluster.example.env) |
| 13 | OpenShift channel / version | self (+ security sign-off) | minutes | Default is `stable-4.18`. Override with `OCP_VERSION=stable-4.19 make tools`. Make a deliberate choice before downloading binaries. | [`README.md` "Where to run the installer"](../README.md) |
| 14 | Subscription IDs (cluster, DNS, private DNS) | self | minutes | `az account list -o table`. Cluster + DNS + private-DNS can all be the same sub (`f54...`) or three different subs in a hub-spoke layout. Document them in `config/cluster.env` (`CLUSTER_SUBSCRIPTION_ID`, `DNS_SUBSCRIPTION_ID`, `PRIVATE_DNS_SUBSCRIPTION_ID`). | [`config/cluster.example.env` line 47–52](../config/cluster.example.env) |
| 15 | Cost approval | finance / self | varies | Running cluster ~$500–800 / month (3 × D8s_v5 control plane + 2–3 × D4s_v5 workers + storage + LBs + IPs). Parked (deallocated) ~$30–50 / month. Optional Azure Bastion ~$140 / month. Install duration: 60–90 minutes. | [`operations.md` "Cost model"](./operations.md) |

## Quick-wins for the impatient

If you have a **greenfield Azure sandbox subscription** that you fully
own, you only need rows **1, 2, 5, 12, 14** to start a PoC today —
Terraform creates the network, parent DNS zone delegation can wait
until row 6, and the rest are post-PoC concerns. The full guided
flow is [`onboarding.md`](./onboarding.md); the condensed commands are
[`quickstart.md`](./quickstart.md).

## Cost callouts

The numbers below are illustrative Sweden Central pay-as-you-go prices
for the default VM SKUs; your tenant pricing, Reserved Instances, and
Savings Plans will move them.

| Mode | Approx. monthly cost | What it includes |
|---|---|---|
| **Running** | $500–$800 | 3 × D8s_v5 control plane + 2 × D4s_v5 workers + 1 × D8s_v5 SR-IOV-style worker + storage + LBs + public IPs |
| **Parked** (deallocated via `make cluster-shutdown`) | $30–$50 | Premium SSD persistence + storage account + static IPs + DNS zones |
| **Optional Azure Bastion** | ~$140 | Standard SKU, AzureBastionSubnet /26 |
| **Install bandwidth** (one-time) | < $5 | Mostly RHCOS pull + container image pull through your firewall |

`make cluster-shutdown` + `make cluster-startup` (see
[`operations.md`](./operations.md)) is the **standard cost-control
pattern** for non-production clusters — work-day pattern is typically
$10–$25/day running + $1–$2/day parked.

## What this checklist does *not* cover

- **Day-2 operations** (monitoring, logging, ACM, GitOps) — these are
  workload concerns, not prerequisites. Pick after the cluster is up.
- **Workload identity** for pods that access Azure resources — covered
  by [`azure-identity-options.md`](./azure-identity-options.md) but not
  required for the install.
- **Cluster upgrades** — covered by [`operations.md`](./operations.md).
- **Disaster recovery** (etcd snapshots, multi-region) — basic
  `make etcd-backup` ships in the repo; multi-region is out of scope.

## After you have everything

1. Confirm row 14 (subscription IDs) by running `az account list -o table`
2. Confirm rows 1+2 by checking `secrets/pull-secret.txt` exists
3. Confirm row 5 by checking `~/.azure/osServicePrincipal.json` exists
   with `chmod 600` and validates against `az login --service-principal`
4. Clone the repo and follow [`onboarding.md`](./onboarding.md) Phase
   Pre-0 → 6
