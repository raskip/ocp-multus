# Customer onboarding — full install playbook

This is the recommended reading and execution order for someone setting
up an OpenShift cluster from this repo for the first time. Each phase
links to a focused doc; finish a phase before moving to the next.

If you are already familiar with UPI installs and just want the
mechanics, skip to **Phase 2** and follow `make preflight && make all`.

## Phase 0 — One-time decisions

Before touching any code, decide four things. Each has a short doc
that explains the tradeoffs and the tenant-policy considerations.

| Decision | Read | Why it matters |
|---|---|---|
| Azure identity model | [`azure-identity-options.md`](./azure-identity-options.md) | Service principal vs managed identity vs user. Some enterprise tenants block SPN creation outright. |
| Installer host location | [`installer-host-requirements.md`](./installer-host-requirements.md) | The host running `openshift-install` needs specific network reach and RBAC; this is the most commonly missed prereq. |
| Jump-host access pattern | [`jump-host-access-decision.md`](./jump-host-access-decision.md) | If `publish: Internal`, you need a way to reach the cluster API. Picks between direct PIP, firewall DNAT, Azure Bastion, or private-only. |
| Outbound + proxy posture | [`required-outbound-destinations.md`](./required-outbound-destinations.md), [`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md) | RHCOS nodes need to reach specific Red Hat / Microsoft / quay.io endpoints. If your tenant has a proxy or TLS-inspection, configure it now. |

Outcome of Phase 0: you know your identity, your installer host, your
jump-host pattern, and your proxy/firewall stance.

## Phase 1 — Network

Two paths. Pick one before you continue.

**Option A — Terraform creates the VNet (default).** No extra prep.
The `terraform/01-network` stack provisions a fresh VNet, subnets,
NSGs, and load balancers. Use this for greenfield labs.

**Option B — Bring Your Own VNet (BYO).** Use this when corp networking
owns VNets and you only get a delegated subnet, or when you have a
hub-spoke topology with shared services. Read
[`network-prereqs.md`](./network-prereqs.md) for the exact subnet
sizing, NSG rules, UDR, and DNS requirements. The
[`examples/network-prereqs-azcli/`](../examples/network-prereqs-azcli/)
directory has copy-pasteable `az`/`pwsh` scripts that create the
prerequisite network exactly the way Terraform expects.

Outcome of Phase 1: either Terraform owns the network, or your network
team has handed you a VNet that satisfies the documented prereqs.

## Phase 2 — Preflight + install

```bash
# 1. Copy example config and fill in your values
cp config/cluster.example.env config/cluster.env
$EDITOR config/cluster.env

# 2. Add secrets locally
mkdir -p secrets
cp /path/to/pull-secret.txt secrets/pull-secret.txt
ssh-keygen -t ed25519 -f secrets/id_ed25519 -N ''

# 3. Authenticate to Azure
az login
export CLUSTER_SUBSCRIPTION_ID="<your-cluster-subscription-id>"
az account set --subscription "$CLUSTER_SUBSCRIPTION_ID"

# 4. Validate prerequisites (Azure RBAC, quotas, network reach, DNS)
make preflight

# 5. Run the full install end-to-end
make all
```

`make preflight` reports any missing permissions, quota gaps, or
network reach problems before you start a 40-minute install that would
fail near the end. Read [`preflight-checklist.md`](./preflight-checklist.md)
for what each check does and how to fix common findings.

`make all` chains the individual `terraform apply` steps, the
ignition generation, the bootstrap upload, and the
`openshift-install wait-for` calls. See [`quickstart.md`](./quickstart.md)
for the per-step breakdown if you want to drive the install manually.

Outcome of Phase 2: a cluster reports `installation complete` and
`oc get nodes` shows control-plane + workers Ready.

## Phase 3 — Post-install fixes

These are handled by `make all` when the relevant condition applies,
but you should know what they do in case you need to re-run them:

- **Image registry storage** — On tenants that block shared-key
  storage access, the default `image-registry` Operator fails. Read
  [`image-registry-options.md`](./image-registry-options.md) for the
  three workarounds (managed identity + RBAC, ephemeral emptyDir, or
  bring-your-own PVC).
- **Multus demo PodSecurity** — The optional Multus validation
  manifests in `manifests/multus/` need PodSecurity Admission labels
  on OpenShift 4.14+. The manifests already include them; if you
  re-render or modify them, keep the `pod-security.kubernetes.io/*`
  labels intact.
- **Ingress via HostNetwork** — When the cluster is internal-only,
  the default ingress requires a pre-created internal apps LB. The
  install handles this; if you customise the topology, read
  `docs/scripts/` for the ingress-related helpers.

## Phase 4 — Day-2 operations

| Operation | Command | When |
|---|---|---|
| Health check | `make cluster-status` | Daily, before any change. |
| Etcd backup | `make etcd-backup` | Before every change; nightly via cron. |
| Stop cluster (save cost) | `make cluster-shutdown` | Lab / dev clusters overnight or over weekends. |
| Start cluster | `make cluster-startup` | When you need the cluster back. |
| Cheaper stop (workers only) | `make workers-down` | When you want API + etcd available but no app compute. |
| Workers back up | `make workers-up` | After `workers-down`. |

`make cluster-shutdown` does a **graceful** stop: drain → in-OS
shutdown → Azure deallocate. **Do not just deallocate VMs in the
Azure portal** — that corrupts etcd. See
[`OPERATIONS.md`](../OPERATIONS.md) for the cost model, prerequisites,
troubleshooting, and end-to-end walkthrough. Per-script CLI reference
lives in [`docs/scripts/`](./scripts/).

For unattended / scheduled execution see
[`SCHEDULING.md`](../SCHEDULING.md) (GitHub Actions, Linux cron,
systemd timers) and [`AZURE-AUTOMATION.md`](../AZURE-AUTOMATION.md)
(Container Apps Jobs, Azure Automation + Hybrid Worker, Functions,
Azure DevOps).

## Phase 5 — Reference + troubleshooting

| Topic | Doc |
|---|---|
| arm64 vs x86_64 gotchas | [`arm64-gotchas.md`](./arm64-gotchas.md) |
| Service principal vs managed identity details | [`azure-credentials.md`](./azure-credentials.md) |
| Architecture diagrams | [`../ARCHITECTURE.md`](../ARCHITECTURE.md), [`../ARCHITECTURE-ASCII.md`](../ARCHITECTURE-ASCII.md) |
| CPU architecture mapping | [`../CPU-ARCHITECTURE.md`](../CPU-ARCHITECTURE.md) |
| Full operations runbook | [`../OPERATIONS.md`](../OPERATIONS.md) |
| Original install walkthrough | [`../DEMO.md`](../DEMO.md) |

## What "this works" looks like

When all five phases complete cleanly, you have:

- A self-managed OpenShift 4.x cluster on Azure VMs, internal-LB
  publishing topology by default.
- An installer host that you can return to for `oc` / `kubectl` /
  `openshift-install` operations.
- A documented start / stop / status / backup workflow that does not
  corrupt etcd.
- A reproducible install: the same `config/cluster.env` plus the same
  network prereqs produces the same cluster on a different
  subscription.

If any phase fails, the relevant doc has a troubleshooting section.
Open an issue on the upstream repo with the failing phase, the
command, and the output if you cannot resolve it.
