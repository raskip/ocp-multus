# Supported CPU architectures

This repository can deploy OpenShift on Azure on either **x86_64** (Intel
Ice Lake D*s_v5) or **arm64** (Ampere Altra D*ps_v5) VMs. The
architecture is controlled by a single setting in
[`config/cluster.env`](../config/cluster.example.env):

```bash
ARCHITECTURE=x86_64   # default
# ARCHITECTURE=arm64
```

The default is `x86_64` because that is the most widely tested CPU
architecture for OpenShift on Azure and matches Red Hat's published
sizing guidance.

## Host CPU vs cluster CPU (they are independent)

> **TL;DR — the laptop you run `make` on does *not* dictate the cluster
> CPU.** The cluster's CPU is set exclusively by `ARCHITECTURE` in
> `config/cluster.env`. The host's CPU only decides which
> `openshift-install` and `oc` *binaries* you download.

This repo's installer/automation is a thin orchestration layer:
`make` calls `terraform` + `az` + `openshift-install`, all of which
talk to Azure to provision VMs and stream RHCOS. There is no
node-architecture coupling between the host running `make` and the
cluster being built. An Apple-silicon Mac (arm64) can deploy an
**x86_64 Azure cluster**, and a Linux/x86_64 jump-host can deploy an
**arm64 Azure cluster**. Mix freely.

The only thing your host arch affects is the tarball you download
from `mirror.openshift.com`:

| Host OS | Host CPU (`uname -s` / `uname -m`) | `openshift-install` tarball | `oc` tarball |
|---|---|---|---|
| Linux | `Linux` / `x86_64` | `openshift-install-linux.tar.gz` | `openshift-client-linux.tar.gz` |
| Linux | `Linux` / `aarch64` | `openshift-install-linux-arm64.tar.gz` | `openshift-client-linux-arm64.tar.gz` |
| macOS | `Darwin` / `x86_64` | `openshift-install-mac.tar.gz` | `openshift-client-mac.tar.gz` |
| macOS (Apple silicon) | `Darwin` / `arm64` | `openshift-install-mac-arm64.tar.gz` | `openshift-client-mac-arm64.tar.gz` |
| Windows | `MINGW*` / `MSYS*` | _not available — use WSL2 or Cloud Shell_ | `openshift-client-windows.zip` (oc only) |

All four POSIX tarballs live under
`https://mirror.openshift.com/pub/openshift-v4/clients/ocp/<channel>/`,
where `<channel>` is typically `stable-4.18` (matching this repo's
defaults).

To grab the right pair automatically, run:

```bash
make tools                                # downloads both ./openshift-install + ./oc
OCP_VERSION=stable-4.19 make tools        # pick a different channel
bash scripts/fetch-openshift-tools.sh --force   # re-download even if present
```

The helper detects the host with `uname` and downloads the matching
tarballs. See [README.md → Where to run the installer](../README.md#where-to-run-the-installer)
for the full list of supported host environments.

> Windows note: there is **no** native-Windows `openshift-install`
> binary upstream. Use WSL2, Azure Cloud Shell, a Linux dev container,
> a GitHub Codespace, or any Linux/macOS host. The Makefile here uses
> `/bin/bash`.

## What the setting controls

| `ARCHITECTURE` (cluster.env) | install-config `architecture` | RHCOS stream key | Azure SIG `architecture` | Uploader Ubuntu SKU | Master / opt-in SR-IOV VM | Worker / bootstrap VM | Uploader VM |
|---|---|---|---|---|---|---|---|
| **`x86_64`** (default) | `amd64` | `architectures.x86_64.*` | `x64` | `server` | `Standard_D8s_v5` | `Standard_D4s_v5` | `Standard_D2s_v5` |
| `arm64` | `arm64` | `architectures.aarch64.*` | `Arm64` | `server-arm64` | `Standard_D8ps_v5` | `Standard_D4ps_v5` | `Standard_D2ps_v5` |

The mapping is enforced by:

- `scripts/render-install-config.sh` — maps cluster.env `ARCHITECTURE`
  to the OpenShift `architecture` field (`x86_64 → amd64`).
- `scripts/fetch-rhcos.sh` — maps to the RHCOS stream JSON key
  (`x86_64 → x86_64`, `arm64 → aarch64`).
- `scripts/render-tfvars.sh` — writes a tiny `*.auto.tfvars` into each
  terraform stack so that `ARCHITECTURE`, `CONTROL_PLANE_VM_SIZE`,
  `WORKER_VM_SIZE`, `SRIOV_WORKER_VM_SIZE`, and `ENABLE_SRIOV` from
  `config/cluster.env` drive terraform too. Wired into the Makefile: every
  `make network|image|bootstrap|control-plane|workers` target depends on
  the `tfvars` target and re-renders the files first.
- `terraform/02-image` — sets the Shared Image Gallery `architecture`
  attribute (`x64` / `Arm64`) and image identifier.
- `terraform/01-network` — picks the uploader VM size and Ubuntu SKU.

## VM-size rationale

The defaults follow Red Hat's [tested integrations and sizing for
OpenShift on Azure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_azure/installation-configuration-parameters):

- **Control plane (`Standard_D8s_v5`, 8 vCPU / 32 GB)** — Red Hat's
  minimum recommended baseline for a self-managed control-plane node on
  Azure. Premium SSD-capable, Accelerated Networking, broadly available
  quota.
- **Worker / bootstrap (`Standard_D4s_v5`, 4 vCPU / 16 GB)** — Red
  Hat's minimum recommended baseline for general-purpose workers.
- **SR-IOV-style worker (`Standard_D8s_v5`)** — optional and created only
  with `ENABLE_SRIOV=true`; same SKU as the master because 4+ NIC slots and
  Accelerated Networking on Intel are required for the Multus / SR-IOV demos.
- **CNF profile worker (`Standard_D8s_v5`)** — with `CNF_PROFILE=true` the
  general worker pool also moves to a 4-NIC SKU to carry the primary plus three
  CNF LAN NICs (OAM/AUSF-UDM/HSS-HLR) with Accelerated Networking. See
  [`cnf-telco-profile.md`](./cnf-telco-profile.md).
- **Uploader (`Standard_D2s_v5`)** — small jumpbox used once during
  install to stream the RHCOS VHD into the private storage account.

## Overrides for non-default sizing

`config/cluster.env` is the documented override point for VM sizes. Edit
it and re-run any `make network|image|bootstrap|control-plane|workers`
target (`scripts/render-tfvars.sh` regenerates the `*.auto.tfvars`
files automatically before terraform runs):

```bash
# config/cluster.env
CONTROL_PLANE_VM_SIZE=Standard_D16s_v5   # heavier control plane
WORKER_VM_SIZE=Standard_D8s_v5
SRIOV_WORKER_VM_SIZE=Standard_D16s_v5  # used only when ENABLE_SRIOV=true
```

> Terraform precedence note: `*.auto.tfvars` files (generated by
> `scripts/render-tfvars.sh`) **override** `terraform.tfvars`. That is
> why the `vm_size` / `sriov_worker_vm_size` lines were removed from the
> `terraform.tfvars.example` files in stacks `03`, `04`, and `05` —
> setting them there would be silently ignored. To force a one-off
> override outside `config/cluster.env`, use a CLI variable instead:
>
> ```bash
> cd terraform/04-control-plane
> terraform apply -var 'vm_size=Standard_D16s_v5'
> ```

For the uploader VM there are dedicated knobs in
`terraform/01-network/terraform.tfvars` (these are read normally because
there is no corresponding `*.auto.tfvars`):

```hcl
uploader_vm_size   = "Standard_D4s_v5"
uploader_image_sku = "server"          # leave blank to follow architecture
```

The v6 generation (`Standard_D8s_v6`, etc.) and AMD variants
(`Standard_D8as_v5`, etc.) can also be set as drop-in replacements.
Verify quota and OpenShift compatibility before changing the SIG image
generation (`hyper_v_generation = "V2"` in `terraform/02-image/main.tf`).

## Switching architecture for an existing deployment

Switching `ARCHITECTURE` for an already-deployed cluster is **not**
supported by re-running terraform; the RHCOS image and gallery resource
are architecture-specific and the existing VMs cannot be hot-swapped to
a different CPU family. To switch:

1. `make cluster-shutdown` and back up etcd
2. `terraform destroy` in stacks 05 → 04 → 03 → 02 → 01 → 00
3. Update `ARCHITECTURE` in `config/cluster.env`
4. Re-render: `make install-config && make ignition`
5. Re-apply each terraform stack in order
6. Restore from etcd backup if needed

For most cases, a fresh cluster on the new architecture is easier than
an in-place switch.
