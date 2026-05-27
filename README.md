# ocp-multus

Self-managed OpenShift Container Platform on Azure VMs using the Azure UPI flow, with optional Multus validation demos.

This repository is a generic public runbook and infrastructure template. It assumes you bring an existing Azure VNet, DNS zone, Red Hat pull secret, `openshift-install`, and `oc`.

## 👉 New to this repo? Start here

If you are setting up a cluster from this template for the first time,
the recommended path is the customer onboarding playbook:

**→ [`docs/onboarding.md`](./docs/onboarding.md)**

It walks you through the four one-time decisions (identity, installer
host, jump-host access, outbound posture), the network setup, the
preflight + install (`make preflight && make all`), the post-install
fixes, and the day-2 lifecycle. Each phase links to a focused
sub-document so you only read what you need.

The rest of this README is reference: what the repo deploys, how it
is laid out, and the original quick-start commands.

## What it deploys

- Public DNS sub-zone delegation for the OpenShift base domain.
- Workload resource group, private DNS zone, storage account, and containers.
- Existing-VNet subnets for control plane, workers, bootstrap, Multus, and SR-IOV-style validation.
- Internal API/MCS and ingress load balancers.
- Private endpoint access to the storage account.
- RHCOS image import from the OpenShift installer release stream.
- Bootstrap, control-plane, and worker VMs.
- Optional Multus macvlan and host-device validation manifests.

The default topology is internal: `publish: Internal`.

## Repository layout

| Path | Purpose |
|---|---|
| `config/cluster.example.env` | Values used to render `install-config.yaml`. |
| `install-config/install-config.yaml.tmpl` | OpenShift install-config template. |
| `scripts/` | Helper scripts for rendering config, resolving RHCOS, uploads, and bootstrap wait. |
| `terraform/00-prereqs` | DNS, resource group, storage, and private DNS prerequisites. |
| `terraform/01-network` | Subnets, NSGs, load balancers, private endpoint, and uploader VM. |
| `terraform/02-image` | RHCOS Azure image and Shared Image Gallery version. |
| `terraform/03-bootstrap` | Bootstrap VM. |
| `terraform/04-control-plane` | Control-plane VMs. |
| `terraform/05-workers` | Worker VMs and optional SR-IOV-style worker. |
| `manifests/multus` | Optional Multus macvlan validation. |
| `manifests/sriov` | Optional host-device / SR-IOV-style validation. |

## CPU architecture

The cluster defaults to **x86_64** (Intel D*s_v5 VMs), driven by a single
`ARCHITECTURE` setting in `config/cluster.env`. Set `ARCHITECTURE=arm64`
to deploy on Azure Ampere D*ps_v5 VMs instead. The setting flows into the
RHCOS image stream, the OpenShift install-config, the Shared Image
Gallery image, the uploader VM, and the default VM sizes. See
[CPU-ARCHITECTURE.md](./CPU-ARCHITECTURE.md) for the full mapping and override
options.

## Where to run the installer

The installer is a Bash + Terraform + Azure CLI pipeline. It runs anywhere
that has those tools and Azure auth — your laptop's CPU does **not** dictate
the cluster's CPU (see [CPU-ARCHITECTURE.md → Host CPU vs cluster CPU](./CPU-ARCHITECTURE.md#host-cpu-vs-cluster-cpu-they-are-independent)).

Supported host environments:

- Linux x86_64 or arm64 (Ubuntu, Debian, RHEL, Fedora, …)
- macOS Intel (x86_64) or Apple silicon (arm64)
- Windows under **WSL2** (Ubuntu/Debian recommended) — native Windows is
  not supported because there is no `openshift-install-windows` upstream
- Azure Cloud Shell (bash) — has `az`, `jq`, `make`, `perl`, `terraform`
  preinstalled. Caveats: 5 GB persistent storage quota, idle session
  timeout (~20 min), source IP is from Azure's Cloud Shell pool (not from
  your network), so don't rely on it for long unattended runs or
  IP-allowlist scenarios. Fine for short interactive sessions.
- A Linux dev container or GitHub Codespace
- A Linux jump-VM (e.g. a small Azure VM with public outbound egress) —
  recommended for long unattended runs
- A GitHub Actions Linux runner for fully automated runs

Required tools on the host:

- Azure CLI (`az`) and a working `az login`
- Terraform ≥ 1.5
- `bash`, `jq`, `make`, `perl`, `curl`, `tar` (`curl`/`tar` are only
  needed by `make tools`)
- `openshift-install` and `oc` matching the host OS + CPU

To fetch `openshift-install` and `oc` automatically:

```bash
make tools                               # autodetects host OS+CPU
OCP_VERSION=stable-4.19 make tools       # override channel/version
bash scripts/fetch-openshift-tools.sh --force   # re-download
```

The helper (`scripts/fetch-openshift-tools.sh`) downloads from
`mirror.openshift.com` and places the binaries at the repo root. The
default channel is `stable-4.18`. See
[CPU-ARCHITECTURE.md → Host CPU vs cluster CPU](./CPU-ARCHITECTURE.md#host-cpu-vs-cluster-cpu-they-are-independent)
for the per-host tarball matrix.

## Quick start

For a guided, end-to-end walkthrough see
[`docs/onboarding.md`](./docs/onboarding.md). The condensed flow:

1. Install host tools: Azure CLI, Terraform, `jq`, `make`, `perl`, `bash` (and `git`). See [Where to run the installer](#where-to-run-the-installer) for supported environments and `make tools` to download `openshift-install` and `oc`.
2. Copy and edit configuration:

   ```bash
   cp config/cluster.example.env config/cluster.env
   $EDITOR config/cluster.env
   ```

   The unified `config/cluster.env` drives all Terraform stacks via
   `scripts/render-tfvars-from-env.sh`; you no longer need to copy
   each `terraform/*/terraform.tfvars.example` by hand.

3. Add secrets locally:

   ```bash
   mkdir -p secrets
   cp /path/to/pull-secret.txt secrets/pull-secret.txt
   ssh-keygen -t ed25519 -f secrets/id_ed25519 -N ''
   ```

4. Authenticate to Azure and export the cluster subscription for helper scripts:

   ```bash
   az login
   export CLUSTER_SUBSCRIPTION_ID="<cluster-subscription-id>"
   az account set --subscription "$CLUSTER_SUBSCRIPTION_ID"
   ```

5. Validate prerequisites, then run the full install:

   ```bash
   make preflight     # checks Azure RBAC, quotas, network reach, DNS
   make all           # full UPI install end-to-end
   ```

   For a step-by-step manual install (useful for debugging or
   customising), follow [`docs/quickstart.md`](./docs/quickstart.md)
   or the original [`DEMO.md`](./DEMO.md) runbook.

## Day-2 lifecycle (stop and restart the cluster)

The cluster can be safely stopped to save Azure compute cost and brought back
later. Just deallocating VMs in Azure is not safe on its own — etcd needs an
in-OS graceful shutdown first. Common operations:

```bash
make cluster-status        # show VM power state, nodes, operators, etcd, cert expiry
make etcd-backup           # snapshot etcd on a control plane node
make cluster-shutdown      # graceful: drain, in-OS shutdown, then Azure deallocate
make cluster-startup       # start VMs, auto-approve CSRs, uncordon, wait Ready
make workers-down          # cheaper option: stop only workers, keep API + etcd up
make workers-up
```

Documentation:

- [`OPERATIONS.md`](./OPERATIONS.md) — full operating runbook (when to use which, cost model, prerequisites, troubleshooting, end-to-end walkthrough).
- [`SCHEDULING.md`](./SCHEDULING.md) — scheduled automation: GitHub Actions, Linux cron, systemd timers.
- [`AZURE-AUTOMATION.md`](./AZURE-AUTOMATION.md) — Azure-native scheduling alternatives: Container Apps Jobs, Azure Automation + Hybrid Worker, Functions, ADO Pipelines.
- [`docs/scripts/`](./docs/scripts/) — per-script CLI reference (synopsis, flags, examples, exit codes).


## Important notes

- This is UPI infrastructure; it is expected that you understand and own the Azure networking and DNS prerequisites.
- The bootstrap ignition is uploaded to a private storage account and consumed through a short-lived user-delegation SAS pointer ignition.
- The Machine API manifests generated by `openshift-install` are removed before ignition generation because Terraform creates the Azure VMs.
- Generated files, pull secrets, Terraform state, kubeconfig, ignition files, and SAS-bearing auto tfvars are ignored by git.
