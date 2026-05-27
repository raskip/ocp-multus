# Azure preflight checklist for OpenShift UPI

This document lists every Azure-side prerequisite the OpenShift installer
and cluster runtime need before you can successfully run
`make prereqs|network|bootstrap|control-plane|workers`. Each item is
verified automatically by `make preflight` (read-only — never modifies
your environment), and is also reproducible manually so the network /
identity / cloud teams can hand back a green tick before you ever clone
this repo on the installer host.

> The `make preflight` target runs the nine sub-checks under
> `scripts/preflight/`. Each one prints `[PASS]`, `[FAIL]`, `[WARN]`, or
> `[SKIP]` with an actionable fix. Run a subset with
> `PREFLIGHT_INCLUDE="01,05,09" make preflight` or
> `PREFLIGHT_EXCLUDE="07,08" make preflight`.

## 1. Azure identity & role assignments — `01-sp-roles.sh`

OpenShift Azure UPI needs credentials twice:

- **Install-time** — `openshift-install create manifests / create
  ignition` validates against ARM (virtualNetwork, locations, VM SKUs,
  HyperVGeneration). **Reader** on the cluster subscription is enough.
- **Cluster runtime** — cloud-controller-manager, ingress-operator,
  cloud-credential-operator, image-registry, machine-api all call ARM
  to create load balancers, public IPs, NSG rules, storage accounts,
  etc. **Contributor on the workload RG** plus **Network Contributor on
  the VNet RG** is the recommended least-privilege scope.

See [`azure-identity-options.md`](./azure-identity-options.md) for the
five identity patterns (sub-scoped SP, RG-scoped SP, Manual cloud-cred
mode, Workload Identity Federation, User-Assigned Managed Identity) and
how to choose between them.

The check resolves the principal from `~/.azure/osServicePrincipal.json`
first (matches what openshift-install would use), and falls back to the
signed-in `az` user.

## 2. VNet + subnets — `02-vnet.sh`

`VIRTUAL_NETWORK` in `NETWORK_RESOURCE_GROUP` must exist before `make
network`. The check prints the VNet's address space and warns if your
`MACHINE_NETWORK_CIDR` doesn't appear to sit inside it.

In **repo-managed network mode** (today's default) the cluster subnets
are created by `terraform/01-network/` — missing subnets are surfaced
as `[WARN]`, not `[FAIL]`. In **BYO-network mode** (PR-H) the subnets
must already exist; the same `[WARN]` lines become hard blockers.

## 3. NSG rules — `03-nsg.sh`

For each named cluster subnet:

| Subnet | Required inbound ports |
|---|---|
| Control plane (`CONTROL_PLANE_SUBNET`) | 6443 (kube-apiserver), 22623 (Machine Config Server), 22 (SSH debug) |
| Worker (`COMPUTE_SUBNET`) | 80, 443 (apps ingress), 22 (SSH debug) |

The check tolerates wildcard rules (`destinationPortRange: "*"`) and
port ranges (`80-443`). NSGs not yet present on the subnet generate a
`[WARN]` — the repo's Terraform attaches them in repo-managed mode.

## 4. UDR attach (firewall egress) — `04-udr.sh`

When the install uses `outboundType: UserDefinedRouting` the
control-plane, worker, bootstrap, **and** Multus subnets all need a
route table with `0.0.0.0/0` → next-hop `VirtualAppliance` pointing at
the firewall's private IP. Today's `terraform/01-network/` attaches the
table only to the worker subnet (Liite B B7); the check surfaces the
gap on the other subnets so you can either extend the attach manually
or enable the BYO-network tfvars toggle once PR-H is merged.

## 5. D-series vCPU quota — `05-quota.sh`

Required minimum for a default cluster (3 masters + 2 workers + 1
bootstrap + 1 optional SR-IOV worker + 1 uploader):

- ~46 vCPU in the `standardDSv5Family` (x86_64) or `standardDPSv5Family`
  (arm64) in the install region.

The check warns under 60 vCPU available to give headroom for retries
and post-install scaling.

## 6. Parent DNS zone + delegation permission — `06-dns-zone.sh`

`terraform/00-prereqs/` creates the `base_domain` sub-zone as a child
of `parent_dns_zone` and writes the `NS` delegation. The parent zone
often lives in a different subscription (`dns_subscription_id`). The
check verifies:

- The parent zone exists in `parent_dns_resource_group`.
- The current identity has `DNS Zone Contributor` (or Contributor /
  Owner) on the zone or its RG so the NS record write succeeds.
- A friendly warning when `base_domain == parent_dns_zone` — the
  current `terraform/00-prereqs/main.tf` tries to *create* `base_domain`
  as a child zone and will fail in that case (Liite B B29).

## 7. spoke ↔ hub VNet peering — `07-peering.sh`

If the spoke VNet has any peerings the check verifies both legs are in
state `Connected` and have `allowForwardedTraffic=true` (without it,
UDR-based firewall egress is dropped at the spoke boundary). If there
are no peerings the check skips — standalone topologies are fine.

## 8. Azure Firewall policy — `08-fw-policy.sh` (opt-in)

Only relevant when egress goes through Azure Firewall. Set
`FW_POLICY_NAME` / `FW_POLICY_RESOURCE_GROUP` /
`FW_POLICY_SUBSCRIPTION_ID` in the environment (the hub subscription
where the firewall lives) and the check verifies the policy exists and
has at least one rule collection group.

If you use a third-party NVA (Palo Alto, Fortinet, Checkpoint, …) the
check skips and points you at
[`required-outbound-destinations.md`](./required-outbound-destinations.md)
so you can build the equivalent rule set in your own vendor.

## 9. Service Principal JSON — `09-sp-json.sh`

`~/.azure/osServicePrincipal.json` must exist with the four required
keys (`clientId`, `clientSecret`, `tenantId`, `subscriptionId`) and be
mode `600`. Both `openshift-install` and the lifecycle scripts
(`cluster-shutdown.sh` / `cluster-startup.sh` / `cluster-etcd-backup.sh`)
fall back to this file when the `az` MSAL cache isn't available — a
common situation in WSL2 + non-interactive shells.

The permissions check is skipped on WSL2 `/mnt/*` paths because the
DrvFs mount always reports `777`.

## CI integration

The orchestrator (`scripts/preflight-checks.sh`) is exit-clean: zero
on `PASS` (with or without `WARN`), non-zero if any check reported
`FAIL`. Wire it into your CI before running `make all` to keep
`Terraform apply` errors from masking misconfigured Azure prerequisites:

```yaml
- name: Preflight
  run: make preflight
- name: Install cluster
  run: make all
```
