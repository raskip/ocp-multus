# Internal-only DNS (no public DNS)

> **TL;DR.** This repo is internal-only by default. It does **not** create any
> public DNS zone or delegation. The cluster's `api` / `api-int` / `*.apps`
> records are served only by the Azure **Private** DNS zone. Public DNS is
> opt-in via `CREATE_PUBLIC_DNS=true`.

## The two DNS layers

OpenShift-on-Azure name resolution in this repo is split in two. They are
independent — the first is optional, the second always exists:

| Layer | Resource | Default | Purpose |
|---|---|---|---|
| **Public** (optional) | `azurerm_dns_zone.public_subzone` + `azurerm_dns_ns_record.delegation` in `terraform/00-prereqs` | **off** | A delegated public sub-zone (`${BASE_DOMAIN}`) under a parent public zone, plus the `NS` delegation record. Only needed for externally reachable clusters or to satisfy an installer that validates a public base-domain zone. |
| **Private** (always) | `azurerm_private_dns_zone.cluster` (`${CLUSTER_NAME}.${BASE_DOMAIN}`), VNet-linked | **on** | Holds the real `api`, `api-int`, and `*.apps` records. Never public. This is what actually resolves the cluster for in-VNet and peered clients. |

Because the cluster topology defaults to `publish: Internal`, the API and
ingress load balancers are internal-only and the **private** zone is all that
is needed for resolution. The **public** layer adds nothing for an internal
install, which is why it is off by default.

## What `CREATE_PUBLIC_DNS=false` does (and does not) do

When `CREATE_PUBLIC_DNS=false` (the default):

- **Not created:** the public parent-zone lookup, the public child sub-zone,
  and the `NS` delegation record. No write ever touches a public/parent zone.
- **Still created:** the private DNS zone and its `api` / `api-int` / `*.apps`
  records, the storage account, private endpoint, etc. — unchanged.
- **Preflight:** `scripts/preflight/06-dns-zone.sh` skips the parent-zone
  existence and `DNS Zone Contributor` permission probes and reports a single
  informational pass.
- **Required config:** `PARENT_DNS_ZONE` / `PARENT_DNS_RESOURCE_GROUP` are no
  longer required by `make tfvars`.

## ⚠ Installer caveat: `baseDomainResourceGroupName`

`install-config.yaml` still sets `platform.azure.baseDomainResourceGroupName`
(from `DNS_RESOURCE_GROUP`). The Azure platform schema requires this field, and
some `openshift-install` versions **validate that a public DNS zone for the
base domain exists in that resource group — even for `publish: Internal`.**

This repo does not silently work around that validation. Pick the option that
fits your environment and **verify against your target OpenShift version**:

1. **Reference an existing public zone for validation only.** Point
   `DNS_RESOURCE_GROUP` at a resource group that already contains a public
   zone for `${BASE_DOMAIN}` (or its parent). Keep `CREATE_PUBLIC_DNS=false`
   so the repo creates no records or delegation; the zone is used purely to
   satisfy the installer's existence check. No public records for the cluster
   are published.
2. **Create the public sub-zone after all.** If your policy allows a delegated
   public sub-zone, set `CREATE_PUBLIC_DNS=true` and provide
   `PARENT_DNS_ZONE` / `PARENT_DNS_RESOURCE_GROUP`. The sub-zone exists but,
   with `publish: Internal`, no externally reachable endpoints are published
   into it.
3. **Confirm your version tolerates no public zone.** Newer OpenShift releases
   relax public-zone validation for internal/user-provisioned-DNS Azure
   installs. If yours does, no public zone is needed at all — verify with a
   `openshift-install create manifests` dry run against an empty
   `DNS_RESOURCE_GROUP` before committing to it.

## Enabling public DNS

Set the toggle and provide the parent-zone coordinates:

```bash
# config/cluster.env
CREATE_PUBLIC_DNS=true
PARENT_DNS_ZONE=example.com
PARENT_DNS_RESOURCE_GROUP=rg-dns-public-example
DNS_SUBSCRIPTION_ID=...        # if the parent zone lives in another subscription
```

Then `make tfvars` re-renders `create_public_dns = true` into
`terraform/00-prereqs/from-env.auto.tfvars`, and `make prereqs` creates the
sub-zone and `NS` delegation. The installer identity needs
`DNS Zone Contributor` (or equivalent) on `PARENT_DNS_RESOURCE_GROUP`.

## Reaching an internal cluster

Internal resolution is unchanged by this toggle. On-prem or workstation clients
reach the cluster API and apps either via an Azure Private DNS Resolver inbound
endpoint in the hub plus an on-prem conditional forwarder for the cluster
sub-zone, or via a jump host inside the VNet. See
[`accessing-the-cluster.md`](./accessing-the-cluster.md) and
[`network-prereqs.md` §5](./network-prereqs.md#5-dns).

## Reference

- `config/cluster.example.env` — `CREATE_PUBLIC_DNS` (and the conditional
  `PARENT_DNS_*` / `DNS_RESOURCE_GROUP` notes).
- `terraform/00-prereqs/variables.tf` — `create_public_dns`.
- `terraform/00-prereqs/main.tf` — the count-gated public DNS resources.
- `scripts/render-tfvars-from-env.sh` — conditional `require` of `PARENT_DNS_*`.
- `scripts/preflight/06-dns-zone.sh` — skips public-zone checks when off.
