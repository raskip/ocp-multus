# OpenShift on Azure UPI with Multus

This runbook deploys a self-managed OpenShift cluster on Azure VMs and then validates secondary pod networking with Multus.

The Terraform stages are intentionally separate so you can inspect and troubleshoot each UPI phase.

## Prerequisites

- Azure subscription access for the cluster resource group.
- Azure subscription access for the public parent DNS zone.
- Existing VNet with enough free address space for the OpenShift subnets.
- Existing `privatelink.blob.core.windows.net` private DNS zone reachable from the cluster VNet, or an equivalent private DNS design.
- Azure CLI, Terraform ≥ 1.6, `jq`, `make`, `bash` ≥ 4, `openshift-install`, and `oc`. Run `make verify` first — it auto-checks the host-tool prerequisites and points to install hints if anything is missing. The cluster's CPU architecture is independent of the host that runs this installer — see [README → Where to run the installer](../README.md#where-to-run-the-installer) for supported host environments and [cpu-architecture.md → Host CPU vs cluster CPU](cpu-architecture.md#host-cpu-vs-cluster-cpu-they-are-independent) for the host-vs-cluster matrix. Use `make tools` to download matching `openshift-install` + `oc` binaries.
- Red Hat pull secret.
- SSH keypair for RHCOS and helper VMs.
- x86_64 D-series VM quota (`Standard_D8s_v5` master, `Standard_D4s_v5` worker) in the chosen region. With `CNF_PROFILE=true` the workers use `Standard_D8s_v5` (4 NIC slots) instead. SR-IOV is opt-in (`ENABLE_SRIOV=true`); off by default the SR-IOV demo worker and its subnet are not created, so its extra 8 vCPU is only consumed when enabled. For an ARM-based deployment, set `ARCHITECTURE=arm64` in `config/cluster.env` and have D*ps_v5 quota instead. See [cpu-architecture.md](cpu-architecture.md).

## Open items — confirm with your platform team

Before running the installer, walk through this short checklist with
whoever owns Azure networking, identity, and the parent DNS zone in your
organisation. Each item is something this repo cannot decide on your
behalf and that causes confusing failures if mis-set.

1. **Outbound internet path.** Will cluster VMs reach `registry.redhat.io`,
   `quay.io`, `mirror.openshift.com`, RHCOS release storage, and
   `management.azure.com` directly, via a corporate firewall/proxy, via an
   Azure NVA, or via Private Endpoints? If a firewall does TLS inspection,
   you need a deliberate `proxy:` / `additionalTrustBundle` plan before
   install. Current automation documents the fields but does **not** yet
   render them from `config/cluster.env`.
2. **DNS.** Internal-only by default — the repo creates no public DNS.
   Public delegation is opt-in (`CREATE_PUBLIC_DNS=true`): when enabled,
   the OpenShift `baseDomain` is a delegated public sub-zone of a parent
   zone your org owns, so confirm whose subscription holds the parent zone
   and that you have write access to add the NS record. See
   [`dns-internal-only.md`](./dns-internal-only.md).
3. **Identity model.** Day-1 install needs an Azure Service Principal (or
   equivalent identity). Day-2 lifecycle scripts (etcd-backup, shutdown,
   startup) need their own credentials — they can reuse the install-time
   SP or use a separate one. See `docs/azure-identity-options.md` (added
   in a separate PR) for the trade-offs.
4. **Ingress publish mode.** This repo defaults to `publish: Internal`
   (internal load balancer). Confirm that the workstation that will run
   `openshift-install wait-for ... install-complete` and `oc` can reach
   the API + apps internal LBs (typically via VPN, ExpressRoute, a
   Linux/customer-provided jump VM, or Azure Bastion). The repo's
   Windows browser/RDP jump host is optional (`CREATE_WINDOWS_JUMP=true`)
   and is not required for install.
5. **Image-registry storage policy.** Some tenant policies block the
   image-registry operator's default storage account creation
   (e.g. `allowSharedKeyAccess=false`). If so, plan to set the operator
   to `Removed` or pre-create a storage account with AAD-only auth. See
   `docs/image-registry-options.md` (added in a separate PR).
6. **Cluster scheduling for control-plane workloads.** Decide up front
   whether system workloads (image-registry, monitoring, ingress) are
   allowed on masters. See [`scheduling.md`](./scheduling.md).

If you can't answer any of these in one sitting, that's the value of the
checklist — pause and get the answer before burning a 90-minute install.

## Configuration

This repo uses a **single config file** as the source of truth:
`config/cluster.env`. Copy the example and edit it for your
environment:

```bash
cp config/cluster.example.env config/cluster.env
$EDITOR config/cluster.env
```

You do **not** need to fill in per-stack `terraform/*/terraform.tfvars`
files by hand. `make tfvars` (auto-run as a prerequisite of every
Terraform target, and as part of `make all`) executes
`scripts/render-tfvars-from-env.sh`, which generates a
`from-env.auto.tfvars` file inside every Terraform stack from your
`config/cluster.env`. The `terraform/*/terraform.tfvars.example` files
that ship in the repo are reference snippets — preflight error
messages point at them when something specific is missing — and not
something you copy into place during a normal install.

> Alternatively, run `make init-config` for an interactive wizard
> (~12 prompts with sensible defaults). See [`quickstart.md`](./quickstart.md).

Create local secrets:

```bash
mkdir -p secrets
cp /path/to/pull-secret.txt secrets/pull-secret.txt
ssh-keygen -t ed25519 -f secrets/id_ed25519 -N ''
```

Authenticate:

```bash
az login
export CLUSTER_SUBSCRIPTION_ID="<cluster-subscription-id>"
az account set --subscription "$CLUSTER_SUBSCRIPTION_ID"
```

## Deploy

The install order below sequences `ignition` BEFORE `network` so the
`infra_id` baked into the route table / NSG names matches the canonical
infraID that openshift-install writes to `install/metadata.json` (the same
infraID it also hard-codes into the cluster's `openshift-config/cloud-provider-config`
ConfigMap). Running `network` before `ignition` was the previous default; it
caused the cluster's cloud provider to look up resources named
`${CLUSTER_NAME}-poc-nsg` while Terraform had created `${CLUSTER_NAME}-${hash}-nsg`,
leaving the ingress operator unable to reconcile the apps LoadBalancer.

```bash
make verify

# 1. DNS, workload resource group, storage, and private DNS
make prereqs

# 2. Render install-config.yaml
make install-config

# 3. Create manifests, remove Machine API manifests, and create ignition.
#    Generates install/metadata.json containing the canonical infraID.
make ignition

# Save the first credential checkpoint: kubeconfig, kubeadmin password,
# installer metadata, SP JSON, pull secret, SSH key, and local state.
make save-credentials

# 4. Subnets, NSGs, internal load balancers, private endpoint, uploader VM,
#    and (only if CREATE_WINDOWS_JUMP=true) a Windows browser/RDP jump host.
#    Auto-triggers `tfvars-refresh` which re-renders 01-network's auto.tfvars
#    with infra_id = the canonical infraID from install/metadata.json.
make network

# Save network outputs, including optional Windows jump-host credentials.
make save-credentials

# 5. Upload RHCOS and create the Azure image
make image

# 6. Upload bootstrap ignition pointer and create bootstrap VM
make bootstrap

# 7. Create control plane
make control-plane

# 8. Wait for bootstrap, then remove bootstrap VM
./openshift-install --dir=install wait-for bootstrap-complete --log-level=info
make destroy-bootstrap

# 9. Create workers
make workers
```

Approve worker CSRs until nodes become ready if you are doing everything
manually. The `make wait-install` target runs this loop automatically.

```bash
while true; do
  oc get csr -o json \
    | jq -r '.items[] | select(.status == {}) | .metadata.name' \
    | xargs -r oc adm certificate approve
  sleep 20
done
```

Wait for completion. For the default PoC topology, this target also:

- switches the default IngressController to `HostNetwork` so it uses the
  repo-created internal apps LB instead of provisioning a second cloud LB
- sets the image-registry operator to `Removed` so tenants that block
  storage shared-key access do not hang the first install

```bash
make wait-install
make save-credentials
```

If you want a managed internal image registry during install, configure
the registry storage option first and run
`AUTO_IMAGE_REGISTRY_REMOVED=false make wait-install`.

See [`credential-backup.md`](./credential-backup.md) for what the
bundle contains and how to use `CREDENTIALS_DIR` when you want a stable
run folder.

## Post-install: ingress on a pre-created internal LB

This repo's Terraform pre-creates an internal apps load balancer
(`lb-ingress-internal-*`) in `terraform/01-network/` and puts workers in
its backend pool. The default `IngressController` is type
`LoadBalancerService`, which makes the cluster try to create a *second*
LB on top of the pre-created one — they conflict and `*.apps` routes
never resolve.

The fix is to patch the IngressController to `HostNetwork`, so it binds
directly to ports 80/443 on the worker nodes that sit behind the
pre-created LB. `make wait-install` runs this automatically for the default repo
topology. If you are recovering a partially installed cluster or you
disabled the automation with `AUTO_INGRESS_HOSTNETWORK=false`, run:

```bash
make ingress-hostnetwork
```

The target is idempotent. It deletes the default IngressController and
recreates it with `endpointPublishingStrategy: HostNetwork` unless it is
already HostNetwork. After ~1-2 minutes the ingress operator reports
Available=True and `*.apps.<basedomain>` resolves through the
pre-created LB.

Verification:

```bash
oc get co ingress
# NAME      VERSION   AVAILABLE   PROGRESSING   DEGRADED
# ingress   4.18.x    True        False         False

oc get ingresscontroller -n openshift-ingress-operator default \
  -o jsonpath='{.spec.endpointPublishingStrategy.type}'
# HostNetwork

# Smoke test (replace baseDomain with yours)
curl -ksI "https://console-openshift-console.apps.<baseDomain>"
# Expect HTTP/1.1 200 OK (or 302 to /auth/...)
```

**Why this is needed:** OpenShift's default ingress strategy on cloud
platforms is `LoadBalancerService` — it provisions a cloud LB
automatically. When you've already pre-created the LB in IaC (so you
can manage its NSG, peering, public-IP, etc.), the operator's
auto-provisioned LB collides. `HostNetwork` skips the operator-side LB
and trusts the IaC-managed one in front of the nodes.

**Common failure:** if you skip this step, the symptom is `*.apps`
DNS resolves to the pre-created LB IP but TCP 443 hangs. Check
`oc get svc -n openshift-ingress router-default` — it should NOT exist
after `make ingress-hostnetwork` (only the host-network listener on
workers).

## Multus / SR-IOV-style validation (optional)

After install, you can validate Multus secondary networking with the
macvlan demo and (if you provisioned the optional SR-IOV-style worker)
the host-device demo. SR-IOV is opt-in (`ENABLE_SRIOV=true`); off by
default the SR-IOV demo worker and its subnet are not created.

For a production telco CNF topology (per-LAN ipvlan NADs, SCTP, node tuning,
dedicated worker NICs, RWX storage, in-cluster registry) see the optional
[`cnf-telco-profile.md`](./cnf-telco-profile.md).

See [`multus-validation.md`](./multus-validation.md) for the full
walkthrough including PodSecurity, SCC, Whereabouts IPAM, and arm64
NIC-name caveats.

## Teardown

Destroy in reverse order:

```bash
make destroy-workers
make destroy-control-plane
make destroy-bootstrap
make destroy-image
make destroy-network
make destroy-prereqs
make clean-install
```

`make destroy` runs the same sequence.

## Pausing and restarting the cluster

You don't have to destroy the cluster to save Azure compute. The day-2
runbook in [`operations.md`](./operations.md) covers:

- `make etcd-backup` — snapshot etcd before any risky operation.
- `make cluster-shutdown` — Red Hat graceful shutdown then `az vm deallocate`.
- `make cluster-startup` — boot, auto-approve kubelet CSRs, uncordon, wait healthy.
- `make workers-down` / `make workers-up` — keep the control plane up and pause workers only.

For unattended scheduled runs (overnight shutdown / morning startup via
GitHub Actions, Linux cron, or systemd timers) see [`scheduling.md`](./scheduling.md).
For Azure-native alternatives when GitHub Actions isn't an option (Azure
Container Apps Jobs, Azure Automation + Linux Hybrid Worker, Functions,
Azure DevOps Pipelines) see [`azure-automation.md`](./azure-automation.md).
For the full CLI reference of every lifecycle script see
[`scripts/`](./scripts/).

The cluster can stay deallocated for up to ~1 year before the internal
kube-apiserver-to-kubelet signer expires and manual CSR recovery is required.
Always take an etcd backup before stopping.

## Notes / gotchas

A short list of things that have bitten people running this installer.
Each one is generic — they apply to UPI installs in restricted enterprise
tenants regardless of the customer.

1. **arm64 NIC names.** On Ampere Altra (`Standard_D*ps_v5`) RHCOS often
   names the secondary NIC `enP*s1` rather than `eth1`. The macvlan demo
   manifest assumes `eth1`. Verify with
   `oc debug node/<worker> -- chroot /host ip -br a` before applying the
   demo. See [`arm64-gotchas.md`](./arm64-gotchas.md).
2. **`publish: Internal` and the installer host.** This repo defaults to
   internal load balancers. That means the host that runs
   `openshift-install wait-for ... install-complete` and `oc` **must be
   able to reach the api / *.apps internal LB IPs** — typically a VPN, an
   ExpressRoute, a jump VM inside the VNet, or Azure Bastion. A laptop
   on the public internet will fail with a confusing `i/o timeout`
   during the install completion wait. Plan installer-host placement
   *before* `make bootstrap`.
3. **Proxy / TLS inspection.** If outbound traffic goes through a
   corporate proxy that intercepts TLS (e.g. Palo Alto, Zscaler), you
   must plan the proxy URL(s), `noProxy`, and proxy CA chain before
   install. Current automation does **not** yet render these from
   `config/cluster.env`, so do not assume `make all` injects
   `additionalTrustBundle` automatically. Otherwise the bootstrap node
   can hang trying to pull RHCOS or release images with `x509` errors.
   See [`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md)
   for the noProxy template and manual field reference.
4. **Image-registry storage.** The image-registry operator tries to
   create its backing storage account by default. Tenant policies that
   block shared-key auth (`allowSharedKeyAccess=false`) will leave the
   operator in `Available=False, Degraded=True`. `make wait-install`
   sets it to `Removed` by default for PoC success; set
   `AUTO_IMAGE_REGISTRY_REMOVED=false` only after configuring managed
   registry storage. See
   [`image-registry-options.md`](./image-registry-options.md) for the
   registry options.
5. **Ingress LoadBalancerService vs pre-created internal LB.** If you
   pre-create an internal apps LB in Terraform, the default
   `IngressController` (LoadBalancerService type) will conflict and the
   `*.apps` route will not work until the IngressController uses
   `HostNetwork`. `make wait-install` runs that conversion automatically
   for the default topology; `make ingress-hostnetwork` remains the
   manual recovery command.
6. **Lifecycle scripts need `oc` on PATH and an active `az`.** After
   `make tools`, copy `./oc` to a PATH location (or `export PATH=$PWD:$PATH`),
   and ensure `az` is logged in (or set
   `AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET`/`AZURE_TENANT_ID` for SP-auth
   in non-interactive contexts). See the `require_oc` / `require_az`
   helpers in `scripts/lib/common.sh`.
