# ocp-multus

[![CI](https://github.com/raskip/ocp-multus/actions/workflows/ci.yml/badge.svg)](https://github.com/raskip/ocp-multus/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

Self-managed OpenShift Container Platform on Azure VMs using the Azure
UPI flow, with optional **Multus secondary-network validation** (macvlan
+ host-device / SR-IOV-style).

This repository is a generic public runbook and infrastructure template.
It assumes you bring an existing Azure VNet (or let Terraform create
one), a delegated public DNS zone, a Red Hat pull secret, and Azure
credentials with the right roles. The installer is Bash + Terraform +
Azure CLI; the cluster is OpenShift's UPI flow.

## ⚠ Before you start — pre-install procurement

Some prerequisites (Red Hat pull secret, Azure subscription roles,
DNS delegation, vCPU quota, firewall outbound allowlist, jump-host
access pattern) take **days or weeks** to procure in an enterprise
tenant. Don't start the install before you have them.

**→ [`docs/pre-install-checklist.md`](./docs/pre-install-checklist.md)** —
single page you can forward to your DNS / network / Entra / subscription
teams in parallel. It also includes an install-phase access map so the
customer knows when each team has to be available.

## 👉 New here? Start with the onboarding playbook

**→ [`docs/onboarding.md`](./docs/onboarding.md)**

It walks you through Phase 0–6:

- **Phase 0** — four one-time decisions (identity, installer host,
  jump-host access, outbound posture)
- **Phase 1** — network (Terraform-managed or BYO VNet)
- **Phase 2** — preflight + install (`make preflight && make all`)
- **Phase 3** — post-install fixes
- **Phase 4** — day-2 lifecycle
- **Phase 5** — reference + troubleshooting
- **Phase 6** — Multus validation (the unique value of this repo —
  see [`docs/multus-validation.md`](./docs/multus-validation.md))

Each phase links to a focused sub-document so you only read what you
need.

If you have done UPI on Azure before and just want the commands, see
[`docs/quickstart.md`](./docs/quickstart.md). For a per-`make`-target
manual walkthrough useful for debugging see
[`docs/manual-install.md`](./docs/manual-install.md).

After install checkpoints, run `make save-credentials` to capture local
kubeconfig, kubeadmin password, Terraform state, SP JSON, and optional
Windows jump-host credentials into a gitignored bundle. See
[`docs/credential-backup.md`](./docs/credential-backup.md).

## What it deploys

- Public DNS sub-zone delegation for the OpenShift base domain.
- Workload resource group, private DNS zone, storage account, and containers.
- Existing-VNet subnets for control plane, workers, bootstrap, Multus, and SR-IOV-style validation.
- Internal API/MCS and ingress load balancers.
- Private endpoint access to the storage account.
- RHCOS image import from the OpenShift installer release stream.
- Bootstrap, control-plane, and worker VMs.
- Optional Multus macvlan and host-device validation manifests.
- Optional **CNF / telco profile** (`CNF_PROFILE=true`, default OFF): three telco LAN subnets, per-LAN worker NICs with Accelerated Networking, Multus ipvlan NADs, SCTP/THP/sysctl node tuning, RWO/RWX storage classes, an in-cluster registry, and an optional Linux bastion. See [`docs/cnf-telco-profile.md`](./docs/cnf-telco-profile.md).

The default topology is internal: `publish: Internal`. A Windows
browser/RDP jump host is available as an opt-in convenience
(`CREATE_WINDOWS_JUMP=true`) but is not required for `make all`;
use your existing VPN/ExpressRoute path, a Linux jump host, hub-FW
DNAT, or Azure Bastion when that fits your tenant better. See
[`docs/accessing-the-cluster.md`](./docs/accessing-the-cluster.md)
for endpoint, DNS, and access-path details.

> **Enterprise TLS-inspection warning:** if your outbound path uses a
> TLS-inspecting proxy/firewall, plan the OpenShift `proxy:` and
> `additionalTrustBundle:` settings before `make all`. The repo documents
> the required fields but does **not** yet auto-render them from
> `config/cluster.env`; without the proxy CA bundle, bootstrap image pulls
> can fail with `x509: certificate signed by unknown authority`.

## Repository layout

| Path | Purpose |
|---|---|
| `bin/` | Operator-facing wrappers: `env.sh`, `install-tools.sh`, `login.sh`, `bootstrap.sh`, `status.sh`, `park.sh`, `start.sh`, `etcd-backup.sh`, `teardown.sh`. |
| `config/cluster.example.env` | Unified config that drives every Terraform stack via `scripts/render-tfvars-from-env.sh`. |
| `install-config/install-config.yaml.tmpl` | OpenShift install-config template. |
| `scripts/` | Helper scripts (render config, resolve RHCOS, uploads, bootstrap wait, sanitize, …). |
| `terraform/00-prereqs` | DNS, resource group, storage, and private DNS prerequisites. |
| `terraform/01-network` | Subnets, NSGs, load balancers, private endpoint, uploader VM, optional Windows jump VM, and optional Linux bastion + CNF LAN subnets (CNF profile). |
| `terraform/02-image` | RHCOS Azure image and Shared Image Gallery version. |
| `terraform/03-bootstrap` | Bootstrap VM. |
| `terraform/04-control-plane` | Control-plane VMs. |
| `terraform/05-workers` | Worker VMs and optional SR-IOV-style worker. |
| `manifests/multus` | Optional Multus macvlan validation manifests. |
| `manifests/sriov` | Optional host-device / SR-IOV-style validation manifests. |
| `manifests/cnf` | Optional CNF profile: Multus ipvlan NADs per telco LAN (see [`docs/cnf-telco-profile.md`](./docs/cnf-telco-profile.md)). |
| `manifests/cnf-platform` | Optional CNF profile: `appworker` pool, scoped SCC, ServiceAccount, PriorityClass. |
| `manifests/node-tuning` | Optional CNF profile: SCTP/THP/sysctl MachineConfigs scoped to the CNF pool. |
| `manifests/storage` | Optional CNF profile: RWO (Azure Disk) + RWX (Azure Files) StorageClasses. |
| `docs/` | All written documentation (onboarding, references, runbooks). |
| `examples/network-prereqs-azcli/` | Copy-pasteable `az`/`pwsh` scripts for BYO-network creation. |
| `examples/jump-host-access/` | Four reference patterns (direct PIP, FW DNAT, Azure Bastion, private-only). |

## Where to run the installer

The installer runs anywhere with `bash` ≥ 4, `make`, `jq`, `az`
(Azure CLI), `terraform` ≥ 1.6, and a working `az login`. Run
`make verify` to auto-check all of these before you start. Your
laptop's CPU does **not** dictate the cluster's CPU — see
[`docs/cpu-architecture.md` → Host CPU vs cluster CPU](./docs/cpu-architecture.md#host-cpu-vs-cluster-cpu-they-are-independent).

Supported host environments:

- Linux x86_64 or arm64 (Ubuntu, Debian, RHEL, Fedora, …)
- macOS Intel (x86_64) or Apple silicon (arm64)
- Windows under **WSL2** (Ubuntu/Debian recommended) — native Windows
  is not supported because there is no `openshift-install-windows`
  upstream
- Azure Cloud Shell (bash) — fine for short interactive sessions
  (5 GB quota, ~20 min idle timeout, source IP from Azure's pool)
- A Linux dev container or GitHub Codespace
- A Linux jump-VM (recommended for long unattended runs)
- A GitHub Actions Linux runner for fully automated runs

To download matching `openshift-install` and `oc`:

```bash
make tools                               # autodetects host OS+CPU
OCP_VERSION=stable-4.19 make tools       # override channel/version
```

The default channel is `stable-4.18`. See
[`docs/cpu-architecture.md`](./docs/cpu-architecture.md) for the per-host
tarball matrix.

## Day-2 lifecycle

The cluster can be safely stopped to save Azure compute cost. Just
deallocating VMs in Azure is **not** safe on its own — etcd needs an
in-OS graceful shutdown first. The repo ships graceful lifecycle
helpers:

```bash
make cluster-status        # VM power state, nodes, operators, etcd, cert expiry
make etcd-backup           # snapshot etcd on a control plane node
make cluster-shutdown      # graceful: drain, in-OS shutdown, then Azure deallocate
make cluster-startup       # start VMs, auto-approve CSRs, uncordon, wait Ready
make workers-down          # cheaper: stop only workers, keep API + etcd up
make workers-up
```

Deep references:

- [`docs/operations.md`](./docs/operations.md) — full operating runbook
  (cost model, prerequisites, troubleshooting, end-to-end walkthrough).
- [`docs/scheduling.md`](./docs/scheduling.md) — scheduled automation:
  GitHub Actions, Linux cron, systemd timers.
- [`docs/azure-automation.md`](./docs/azure-automation.md) — Azure-native
  scheduling alternatives: Container Apps Jobs, Azure Automation +
  Hybrid Worker, Functions, ADO Pipelines.
- [`docs/scripts/`](./docs/scripts/) — per-script CLI reference.

## Important notes

- This is UPI infrastructure; you are expected to understand and own
  the Azure networking and DNS prerequisites.
- The bootstrap ignition is uploaded to a private storage account and
  consumed through a short-lived user-delegation SAS pointer ignition.
- The Machine API manifests generated by `openshift-install` are removed
  before ignition generation because Terraform creates the Azure VMs.
- Generated files, pull secrets, Terraform state, kubeconfig, ignition
  files, and SAS-bearing auto tfvars are ignored by git.

## Contributing & security

- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — ground rules and the pre-push
  checks (sanitize-check, shellcheck, `bash -n`, `terraform fmt`/`validate`).
- [`SECURITY.md`](./SECURITY.md) — how to report a vulnerability and how
  secrets are kept out of this repo.
- [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) — Contributor Covenant.

## License

Licensed under the [MIT License](./LICENSE).
