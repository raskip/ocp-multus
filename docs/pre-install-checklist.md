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
Service Principal + role assigns  | 5 min (if you have app-reg + RBAC-admin rights) | days–weeks (Entra + RBAC approvals)
Public DNS parent zone + delegate | minutes (if you own the zone)    | 1–2 weeks (DNS team ticket)
VNet + subnet allocation          | n/a (Terraform creates)          | 1–2 weeks (network team ticket)
UDR / firewall outbound allowlist | minutes (Azure Firewall lab)     | 1–2 weeks (security team)
Proxy CA bundle (if TLS-inspect)  | n/a                              | days (security team)
Image-registry storage decision   | minutes                          | days (security team review)
Jump-host access pattern          | minutes (A direct PIP)           | days (B/C/D + change ticket)
Source IP (`ADMIN_SSH_SOURCE_IP`) | `curl ifconfig.me`               | ask IT for VPN exit CIDR
OpenShift version pin             | minutes (pick `stable-4.18`)     | days (security approves channel)
Subscription IDs (workload + public + private DNS) | minutes (`az account list`) | minutes (often need to ask 3 owners)
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
| 4 | D-series vCPU quota ≥ 46 in target region | Azure support | 1–3 days | `az vm list-usage -l <region> -o table` → file a quota-increase ticket if `standardDSv5Family` `currentValue + 46 > limit`. Add 2 vCPU if you opt into the Windows jump host (`CREATE_WINDOWS_JUMP=true`). | [`preflight-checklist.md` §5](./preflight-checklist.md) |
| 5 | Service Principal (E1–E5 pattern) | Entra admin + Azure RBAC admin | days–weeks | First decide who can **create the Entra app/SP** (tenant app-registration setting, Application Developer, Cloud Application Administrator, or equivalent). Then decide who can **assign Azure roles** (`Microsoft.Authorization/roleAssignments/write` via Owner, User Access Administrator, Role Based Access Control Administrator, or custom role) at each required scope. The install SP typically gets Reader on the cluster subscription, Contributor on the workload RG, Network Contributor on the VNet RG, DNS Zone Contributor on the public parent zone, Private DNS Zone Contributor on the private-DNS zone/RG if `privatelink.blob.core.windows.net` is centralised, and Storage Blob Data Owner for installer uploads (or permission for Terraform to create that assignment). Save JSON to `~/.azure/osServicePrincipal.json` with chmod 600. | [`azure-credentials.md`](./azure-credentials.md#permissions-the-person-setting-up-the-sp-needs), [`azure-identity-options.md`](./azure-identity-options.md) |
| 6 | Public parent DNS zone + write access | DNS team | 1–2 weeks | The repo creates a child public zone (`${BASE_DOMAIN}` under `${PARENT_DNS_ZONE}`) in the DNS resource group and writes one NS-record into the parent. Your SP needs **DNS Zone Contributor** on the DNS resource group that contains/receives the child zone; parent-zone-only scope is not enough for the default Terraform path. | [`network-prereqs.md` §5](./network-prereqs.md) |
| 7 | VNet (only if BYO-network) | network team | 1–2 weeks | Subnet sizing: control plane /27, workers /24, bootstrap /28 (room for bootstrap + uploader + optional Windows jump), Multus /24, SR-IOV-style /24. NSGs allow intra-cluster traffic. Hand them [`docs/network-prereqs.md`](./network-prereqs.md). If the cluster needs to talk to on-prem resources (or on-prem clients need to reach the cluster via `publish: Internal`), peer this spoke VNet to your hub VNet (the hub typically holds the ExpressRoute / S2S VPN gateway); see [`network-prereqs.md` §6](./network-prereqs.md#6-vnet-peering). | [`network-prereqs.md`](./network-prereqs.md), [`examples/network-prereqs-azcli/`](../examples/network-prereqs-azcli/) |
| 8 | Outbound destinations allowed through your firewall / NVA | network-security team | 1–2 weeks | Vendor-neutral FQDN/IP/port list to add to your Palo Alto / Fortinet / Checkpoint / Azure Firewall rule base | [`required-outbound-destinations.md`](./required-outbound-destinations.md) |
| 9 | Proxy / TLS-inspection decision | security + network team | days | If your outbound path uses an HTTP proxy or terminates TLS, get the proxy URL(s), `noProxy` CIDRs/domains, and the PEM CA chain **before** `make all`. Current automation does **not** yet render `proxy:` / `additionalTrustBundle:` from `config/cluster.env`; do not assume the CA is injected automatically. Without this design, bootstrap/release image pulls can fail with `x509: certificate signed by unknown authority`. | [`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md) |
| 10 | Image-registry storage decision | security team | days | Tenants that block `allowSharedKeyAccess` cannot use the default managed registry storage. The repo's PoC default automatically sets the registry to **Removed** during `make wait-install` so install can complete. If you need an in-cluster registry, opt out with `AUTO_IMAGE_REGISTRY_REMOVED=false` and configure storage first. | [`image-registry-options.md`](./image-registry-options.md) |
| 11 | Jump-host access pattern (A/B/C/D) | network-security team | days | Decide before `make prereqs`. A = direct PIP (often blocked), B = hub-FW DNAT, C = Azure Bastion, D = private-only via VPN/ExpressRoute. The repo's Windows browser/RDP jump host is optional (`CREATE_WINDOWS_JUMP=true`) and not required for install. Bastion is also optional and is **not** deployed by `make all`; the Bastion example requires explicit opt-in. | [`jump-host-access-decision.md`](./jump-host-access-decision.md), [`installer-host-requirements.md`](./installer-host-requirements.md) |
| 12 | `ADMIN_SSH_SOURCE_IP` (your egress IP / VPN exit CIDR) | self or IT | minutes | `curl ifconfig.me` for personal, or ask IT for the corporate VPN exit CIDR. Used in NSG inbound rules for the uploader VM and for any jump-host pattern that permits SSH from your workstation/VPN. | [`config/cluster.example.env` line 67](../config/cluster.example.env) |
| 13 | OpenShift channel / version | self (+ security sign-off) | minutes | Default is `stable-4.18`. Override with `OCP_VERSION=stable-4.19 make tools`. Make a deliberate choice before downloading binaries. | [`README.md` "Where to run the installer"](../README.md) |
| 14 | Subscription IDs (workload + public DNS zone owner + private DNS zone owner) | self | minutes | `az account list -o table`. The three env vars in `config/cluster.env` map to three **DNS/identity scopes** — not "cluster + connectivity + ???". `CLUSTER_SUBSCRIPTION_ID` = workload VMs/VNet/RG. `DNS_SUBSCRIPTION_ID` = owner of the public parent zone (often a central corp-IT sub). `PRIVATE_DNS_SUBSCRIPTION_ID` = owner of `privatelink.blob.core.windows.net` (often co-located with a connectivity/hub sub, but conceptually a separate scope). **Single-subscription sandbox: set all three vars to the same UUID.** Connectivity/hub subscription (if you peer to a hub VNet) is **not** a separate env var — it is consumed via subnet ARM IDs in BYO-network mode (each `/subscriptions/<UUID>/...` subnet ID embeds the hub sub UUID); see [`network-prereqs.md` §6](./network-prereqs.md#6-vnet-peering). | [`config/cluster.example.env` line 47–52](../config/cluster.example.env) |
| 15 | Cost approval | finance / self | varies | Running cluster ~$500–800 / month (3 × D8s_v5 control plane + 2–3 × D4s_v5 workers + storage + LBs + IPs). Parked (deallocated) ~$30–50 / month. Optional Azure Bastion ~$140 / month. Install duration: 60–90 minutes. | [`operations.md` "Cost model"](./operations.md) |

## Installation phases and when access is needed

Use this table to decide **who must be available at each point**. The
same person can fill multiple roles in a sandbox subscription; in an
enterprise tenant these are usually different teams and PIM activations.

| When | Command / activity | Access used | Who to involve | Why it is needed |
|---|---|---|---|---|
| Procurement | Rows 1–15 above | No repo access yet | Red Hat account owner, Entra admin, subscription owner, DNS team, network/security team | Gather the external artefacts and approvals before the installer host exists. |
| SP creation | `az ad sp create-for-rbac --skip-assignment` | Entra app-registration permission | Entra admin or Application Developer / Cloud Application Administrator | Creates the app registration, Service Principal, and one-time client secret. Does **not** grant Azure RBAC. |
| Role grants | `az role assignment create ...` | `Microsoft.Authorization/roleAssignments/write` at each target scope | Subscription / RG / DNS-zone owner, typically Owner, User Access Administrator, or Role Based Access Control Administrator | Grants the install SP its scoped Azure roles. If scopes live in different subscriptions, each owner must grant their part. |
| Local verification | `make verify` | Local tools + active `az` session + files on disk | Installer operator | Catches missing `bash`, `jq`, `az`, `terraform`, pull secret, SSH key, and SP JSON before Azure changes start. |
| Azure preflight | `make preflight` | Read-only Azure queries using the current identity / install SP | Installer operator, with RBAC/DNS/network teams on-call for fixes | Confirms roles, quota, DNS, VNet, peering, NSG, UDR, and private-DNS prerequisites before Terraform mutates anything. |
| Prereqs | `make prereqs` | Cluster subscription Reader/Contributor, parent DNS write, workload RG/storage permissions | Installer operator; subscription owner if the workload RG is not pre-created; DNS owner if parent zone is centralised | Creates or uses the workload RG, creates public/cluster DNS zones, delegates the sub-zone, creates the installer storage account, and may create a storage data-plane role assignment. |
| Network | `make network` | Workload RG Contributor, VNet RG Network Contributor, private-DNS write | Network/private-DNS owner if BYO or hub/private-DNS is centralised | Creates cluster-side LBs, private endpoint, uploader VM, and optional Windows jump host; links/writes Private Endpoint DNS. |
| Image + VMs | `make image`, `make bootstrap`, `make control-plane`, `make workers` | Workload RG Contributor + storage blob data access | Installer operator | Uploads RHCOS/ignition artefacts and creates OpenShift VMs, disks, NICs, and backend-pool attachments. |
| Bootstrap wait | `make wait-bootstrap`, `make wait-install` | Network reach to `api.<cluster>.<base_domain>:6443` + kubeconfig generated by installer | Installer operator + network team if API is private | Waits for control plane and operators. With `publish: Internal`, the installer host must reach the private API path via VPN/ER, Bastion, jump host, or firewall DNAT. |
| Day-2 access | `oc`, web console, lifecycle scripts | `install/auth/kubeconfig`, kubeadmin or configured IdP, and Azure VM rights for lifecycle | Cluster admin + operations team | Use the cluster, validate Multus, park/start, and run backups. Persist credentials outside `install/` after install. |

## Quick-wins for the impatient

If you have a **greenfield Azure sandbox subscription** that you fully
own, you only need rows **1, 2, 5, 12, 14** to start a PoC today —
Terraform creates the network, parent DNS zone delegation can wait
until row 6, and the rest are post-PoC concerns. Row 14 in a
single-sub PoC is just pasting the same UUID into all three env
vars — takes 10 seconds. The full guided flow is
[`onboarding.md`](./onboarding.md); the condensed commands are
[`quickstart.md`](./quickstart.md).

Exception: if a TLS-inspecting proxy/firewall is in the outbound path,
row **9** is not optional even for a PoC. Get the CA/proxy decision
settled before install; the current repo does not auto-inject it.

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
