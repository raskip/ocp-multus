# Customer onboarding — full install playbook

This is the recommended reading and execution order for someone setting
up an OpenShift cluster from this repo for the first time. Each phase
links to a focused doc; finish a phase before moving to the next.

If you are already familiar with UPI installs and just want the
mechanics, skip to **Phase 2** and follow `make preflight && make all`,
or read [`quickstart.md`](./quickstart.md) for the condensed flow.

> **Phase Pre-0 — Procurement (do this first).** Before any of the
> decisions below, gather the credentials, quota, DNS delegation, and
> firewall allowlist your tenant needs. See
> [`pre-install-checklist.md`](./pre-install-checklist.md) — single page
> you can forward to your DNS / network / Entra / subscription teams
> in parallel. **Procurement** (gather things from owners outside this
> repo) and **decisions** (pick a pattern from the options below) are
> two separate workstreams; Pre-0 is the former, Phase 0 is the latter.

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

# 4. Verify host tools + local files (bash, make, jq, az, terraform,
#    config/cluster.env, secrets/pull-secret.txt, secrets/id_ed25519.pub)
make verify

# 5. Validate Azure prerequisites (RBAC, quotas, network reach, DNS)
make preflight

# 6. Run the full install end-to-end
make all
```

`make verify` is the host-side check (binaries + versions + local
files); `make preflight` is the Azure-side check (cloud RBAC, quotas,
network reach, DNS delegation). `make all` re-runs `make verify`
automatically as its first step, so you can skip step 4 if you're
going straight to step 6 — but running it explicitly catches a
missing `jq` or out-of-date `terraform` in two seconds instead of
finding out about it once `make preflight` starts shelling out.

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
  labels intact. See [`multus-validation.md`](./multus-validation.md)
  for the full walk-through when you want to run the demo (Phase 6).
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
[`operations.md`](./operations.md) for the cost model, prerequisites,
troubleshooting, and end-to-end walkthrough. Per-script CLI reference
lives in [`docs/scripts/`](./scripts/).

For unattended / scheduled execution see
[`scheduling.md`](./scheduling.md) (GitHub Actions, Linux cron,
systemd timers) and [`azure-automation.md`](./azure-automation.md)
(Container Apps Jobs, Azure Automation + Hybrid Worker, Functions,
Azure DevOps).

## Phase 5 — Reference + troubleshooting

| Topic | Doc |
|---|---|
| arm64 vs x86_64 gotchas | [`arm64-gotchas.md`](./arm64-gotchas.md) |
| Service principal vs managed identity details | [`azure-credentials.md`](./azure-credentials.md) |
| Architecture diagrams | [`architecture.md`](./architecture.md), [`architecture-ascii.md`](./architecture-ascii.md) |
| CPU architecture mapping | [`cpu-architecture.md`](./cpu-architecture.md) |
| Full operations runbook | [`operations.md`](./operations.md) |
| Manual install walkthrough (per `make` target) | [`manual-install.md`](./manual-install.md) |
| Quickstart (UPI-veteran condensed flow) | [`quickstart.md`](./quickstart.md) |

## Phase 6 — Multus secondary-network validation (optional)

This repo is named `ocp-multus` because its original purpose was to
demo Multus secondary pod networking on stock Azure VMs. After your
cluster is `Ready`, you can validate that the secondary networking is
wired correctly end-to-end with two demos:

- **macvlan** — attaches a virtual interface on top of each worker's
  secondary NIC (`snet-ocp-multus` subnet), assigns pod IPs via
  Whereabouts IPAM, and runs a two-NIC verification pod.
- **host-device / SR-IOV-style** — moves a dedicated NIC into a pod
  network namespace on the optional SR-IOV-style worker (when
  `enable_sriov_worker=true`).

Both demos require the **`privileged` SCC** and a namespace with the
`privileged` PodSecurity profile (required for the macvlan / host-device
CNI plugins to manipulate host NICs from inside the pod network
namespace).

**→ [`multus-validation.md`](./multus-validation.md)** for the full
walk-through (prereqs, NIC-name confirmation, Whereabouts IPAM, arm64
gotchas, cleanup).

Skip this phase if the cluster does not need secondary pod NICs.

## What "this works" looks like

When all six phases complete cleanly, you have:

- A self-managed OpenShift 4.x cluster on Azure VMs, internal-LB
  publishing topology by default.
- An installer host that you can return to for `oc` / `kubectl` /
  `openshift-install` operations.
- A documented start / stop / status / backup workflow that does not
  corrupt etcd.
- A reproducible install: the same `config/cluster.env` plus the same
  network prereqs produces the same cluster on a different
  subscription.
- (If you ran Phase 6) A working Multus secondary-network demo, proving
  that pods can attach to a second pod NIC backed by your Azure subnet.

If any phase fails, the relevant doc has a troubleshooting section.
Open an issue on the upstream repo with the failing phase, the
command, and the output if you cannot resolve it.
