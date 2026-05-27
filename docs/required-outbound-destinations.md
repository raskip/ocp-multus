# Required outbound destinations

OpenShift on Azure UPI clusters that egress through a customer-owned
firewall (Azure Firewall, Palo Alto, Fortinet, Check Point, Cisco,
or any other NVA) must allow the destinations listed below. The
lists are **vendor-neutral**: pick the FQDN, IP range, port, and
protocol columns and translate them into the syntax your firewall
team uses.

If your firewall **terminates TLS** (i.e. inspects HTTPS by
re-signing certificates with an internal CA), also read
[`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md) —
allowing the destinations is necessary but not sufficient when
TLS-inspection is in the path.

> **Scope.** This document covers what the cluster nodes and the
> installer host need to reach on the public internet (or via
> private endpoints inside the spoke VNet). Internal cluster
> traffic (pod-to-pod, node-to-node, control-plane-to-etcd) stays
> inside the spoke VNet and is governed by NSG rules — see
> [`network-prereqs.md`](./network-prereqs.md) once that document
> lands.

---

## 1. OpenShift / Red Hat registries (install + Day-2)

Required to pull operator images, RHCOS, and OpenShift release
content. All over TCP/443.

| FQDN | Purpose | Notes |
|---|---|---|
| `quay.io` | Primary container registry for Red Hat images | Required for bootstrap and Day-2 |
| `cdn.quay.io` | Quay CDN for image layer pulls | Often a separate Akamai / Cloudfront CIDR — allow by FQDN, not IP |
| `cdn01.quay.io` | Quay CDN secondary | Same as above |
| `cdn02.quay.io` | Quay CDN secondary | |
| `cdn03.quay.io` | Quay CDN secondary | |
| `registry.redhat.io` | Red Hat container registry (UBI base images, operators) | Auth via pull-secret |
| `registry.connect.redhat.com` | Red Hat Connect partner registry | Used by some operators |
| `cloud.redhat.com` | Telemetry and Hybrid Cloud Console | Telemetry can be disabled but cluster monitoring still tries |
| `console.redhat.com` | Hybrid Cloud Console — telemetry, OCM API | Used by Insights / cluster registration |
| `api.openshift.com` | OpenShift Cluster Manager API | Cluster registration, subscription validation |
| `mirror.openshift.com` | OpenShift binary mirror — `openshift-install`, `oc`, RHCOS images | Used by `make tools` and on bootstrap |
| `*.openshiftapps.com` | Hosted operators, samples | Optional but recommended |
| `art-rhcos-ci.s3.amazonaws.com` | RHCOS image staging (some releases) | Allow if you see staging URLs in installer logs |
| `releases-rhcos-art.cloud.privileged.psi.redhat.com` | RHCOS release index | Used when downloading the matching RHCOS image |

**Quay IP ranges** are not stable — always allow Quay by FQDN, never by IP. If
your firewall does not support FQDN rules, request a downloadable IP feed from
your firewall vendor or arrange an outbound proxy that supports FQDN allow-lists.

---

## 2. Azure platform (management + identity)

The cluster needs to reach the Azure Resource Manager (ARM) plane
to provision LoadBalancers, attach disks, and read VM metadata.

| FQDN | Purpose | Notes |
|---|---|---|
| `management.azure.com` | ARM control plane (cloud-controller-manager, machine-api) | TCP/443 |
| `login.microsoftonline.com` | Entra ID / OAuth2 token endpoint | TCP/443 |
| `login.windows.net` | Legacy Entra ID endpoint | TCP/443, some SDKs still use it |
| `graph.microsoft.com` | Microsoft Graph API | Optional — only if Day-2 operators integrate |
| `<region>.management.azure.com` | Regional ARM data plane | TCP/443; `<region>` matches your `LOCATION` |
| `169.254.169.254` (IMDS) | Azure Instance Metadata Service | Loopback to host; no firewall traversal needed but do **not** add a DROP rule for it |
| `168.63.129.16` (WireServer) | Azure platform agent — DHCP, health probes, extension status | Loopback; do **not** block |

`168.63.129.16` and `169.254.169.254` must remain reachable from
every node. Some firewall vendors propose blocking the metadata
endpoint as a "best practice" — that breaks Azure VMs entirely.

---

## 3. Azure Blob Storage (RHCOS image, bootstrap ignition, image-registry)

If you use the repo's default flow, ignition files and the RHCOS
VHD are uploaded into a workload-RG storage account fronted by a
Private Endpoint. Cluster nodes resolve `*.blob.core.windows.net`
to a private IP inside the spoke VNet via the
`privatelink.blob.core.windows.net` private DNS zone — no
firewall traversal needed for those reads.

If the cluster also needs to reach **public** blob endpoints (for
example, for an external backup target or a registry stored in a
storage account outside the spoke), allow:

| FQDN | Purpose |
|---|---|
| `*.blob.core.windows.net` | Public blob endpoint when not using PE |
| `*.queue.core.windows.net` | Optional — some operators use queues |
| `*.table.core.windows.net` | Optional |
| `*.file.core.windows.net` | Only if Azure Files volumes are used |

---

## 4. NTP, DNS, and time sync

| Destination | Port | Purpose |
|---|---|---|
| `time.windows.com` | UDP/123 | Default chrony NTP source on RHCOS |
| Customer NTP / GTM | UDP/123 | If you override chrony to use internal time sources |
| Customer recursive DNS | UDP/53, TCP/53 | Only if you forward `*.<base_domain>` to Azure DNS via on-prem resolver |

---

## 5. Optional integrations (allow only if used)

| FQDN | Purpose |
|---|---|
| `*.redhat.com` | Documentation, knowledge base, support attachments |
| `subscription.rhsm.redhat.com` | RHEL entitlement (only if RHEL workers, not RHCOS) |
| `cert-api.access.redhat.com` | Red Hat Insights certificate exchange |
| `api.access.redhat.com` | Red Hat Customer Portal API |
| `prod.acr.io` and operator-specific registries | OperatorHub installs from non-Red Hat catalogs |

---

## 6. Minimum allow-list for a basic UPI install

If you want a single tight allow-list to start from, this set has
been sufficient for `make bootstrap` through `make wait-install`
in a UPI install with the default operator set:

```text
TCP/443  quay.io
TCP/443  cdn.quay.io
TCP/443  cdn01.quay.io
TCP/443  cdn02.quay.io
TCP/443  cdn03.quay.io
TCP/443  registry.redhat.io
TCP/443  registry.connect.redhat.com
TCP/443  cloud.redhat.com
TCP/443  console.redhat.com
TCP/443  api.openshift.com
TCP/443  mirror.openshift.com
TCP/443  releases-rhcos-art.cloud.privileged.psi.redhat.com
TCP/443  management.azure.com
TCP/443  <region>.management.azure.com
TCP/443  login.microsoftonline.com
TCP/443  graph.microsoft.com
UDP/123  time.windows.com
```

Add more from sections 1–5 as Day-2 operators come online.

---

## 7. Validating with logs from your firewall

After `make bootstrap` starts, your firewall logs are the fastest
way to identify a missing allow:

| Firewall | Where to look |
|---|---|
| Azure Firewall | `AzureDiagnostics` → `OperationName = AzureFirewallApplicationRuleLog` / `AzureFirewallNetworkRuleLog`, filter to `action_s = "Deny"` |
| Palo Alto | Traffic log, filter `action eq deny` + source = spoke CIDR |
| Fortinet | Forward Traffic log, filter `action=deny` + srcip = spoke CIDR |
| Check Point | SmartLog, blade `Firewall`, filter `Action: Drop` + source = spoke CIDR |

Look for repeated DNS lookups for hosts in section 1, or HTTPS
connect attempts to those FQDNs — that is the most reliable
signal that an allow rule is missing.

---

## 8. Identifying a TLS-inspection problem (vs a missing allow)

If your firewall logs show the request **succeeded** (e.g. Azure
Firewall logs `Allow` for `quay.io:443`) but the installer still
reports `x509: certificate signed by unknown authority`, you have
a TLS-inspection problem, not a missing allow. Continue with
[`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md).
