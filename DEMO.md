# OpenShift on Azure UPI with Multus

This runbook deploys a self-managed OpenShift cluster on Azure VMs and then validates secondary pod networking with Multus.

The Terraform stages are intentionally separate so you can inspect and troubleshoot each UPI phase.

## Prerequisites

- Azure subscription access for the cluster resource group.
- Azure subscription access for the public parent DNS zone.
- Existing VNet with enough free address space for the OpenShift subnets.
- Existing `privatelink.blob.core.windows.net` private DNS zone reachable from the cluster VNet, or an equivalent private DNS design.
- Azure CLI, Terraform, `jq`, `make`, `perl`, `bash`, `openshift-install`, and `oc`. The cluster's CPU architecture is independent of the host that runs this installer — see [README → Where to run the installer](README.md#where-to-run-the-installer) for supported host environments and [CPU-ARCHITECTURE.md → Host CPU vs cluster CPU](CPU-ARCHITECTURE.md#host-cpu-vs-cluster-cpu-they-are-independent) for the host-vs-cluster matrix. Use `make tools` to download matching `openshift-install` + `oc` binaries.
- Red Hat pull secret.
- SSH keypair for RHCOS and helper VMs.
- x86_64 D-series VM quota (`Standard_D8s_v5` master, `Standard_D4s_v5` worker) in the chosen region. For an ARM-based deployment, set `ARCHITECTURE=arm64` in `config/cluster.env` and have D*ps_v5 quota instead. See [CPU-ARCHITECTURE.md](CPU-ARCHITECTURE.md).

## Open items — confirm with your platform team

Before running the installer, walk through this short checklist with
whoever owns Azure networking, identity, and the parent DNS zone in your
organisation. Each item is something this repo cannot decide on your
behalf and that causes confusing failures if mis-set.

1. **Outbound internet path.** Will cluster VMs reach `registry.redhat.io`,
   `quay.io`, `mirror.openshift.com`, RHCOS release storage, and
   `management.azure.com` directly, via a corporate firewall/proxy, via an
   Azure NVA, or via Private Endpoints? If a firewall does TLS inspection,
   you need an `additionalTrustBundle` in `install-config.yaml`.
2. **DNS delegation.** The OpenShift `baseDomain` must be a delegated
   public sub-zone of a parent zone your org owns. Confirm whose
   subscription holds the parent zone and that you have write access to
   add the NS record.
3. **Identity model.** Day-1 install needs an Azure Service Principal (or
   equivalent identity). Day-2 lifecycle scripts (etcd-backup, shutdown,
   startup) need their own credentials — they can reuse the install-time
   SP or use a separate one. See `docs/azure-identity-options.md` (added
   in a separate PR) for the trade-offs.
4. **Ingress publish mode.** This repo defaults to `publish: Internal`
   (internal load balancer). Confirm that the workstation that will run
   `openshift-install wait-for ... install-complete` and `oc` can reach
   the API + apps internal LBs (typically via VPN, ExpressRoute, jump
   VM, or Azure Bastion).
5. **Image-registry storage policy.** Some tenant policies block the
   image-registry operator's default storage account creation
   (e.g. `allowSharedKeyAccess=false`). If so, plan to set the operator
   to `Removed` or pre-create a storage account with AAD-only auth. See
   `docs/image-registry-options.md` (added in a separate PR).
6. **Cluster scheduling for control-plane workloads.** Decide up front
   whether system workloads (image-registry, monitoring, ingress) are
   allowed on masters. See [`SCHEDULING.md`](./SCHEDULING.md).

If you can't answer any of these in one sitting, that's the value of the
checklist — pause and get the answer before burning a 90-minute install.

## Configuration

Copy examples and edit them for your environment:

```bash
cp config/cluster.example.env config/cluster.env
cp terraform/00-prereqs/terraform.tfvars.example terraform/00-prereqs/terraform.tfvars
cp terraform/01-network/terraform.tfvars.example terraform/01-network/terraform.tfvars
cp terraform/02-image/terraform.tfvars.example terraform/02-image/terraform.tfvars
cp terraform/03-bootstrap/terraform.tfvars.example terraform/03-bootstrap/terraform.tfvars
cp terraform/04-control-plane/terraform.tfvars.example terraform/04-control-plane/terraform.tfvars
cp terraform/05-workers/terraform.tfvars.example terraform/05-workers/terraform.tfvars
```

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

```bash
make verify

# 1. DNS, workload resource group, storage, and private DNS
make prereqs

# 2. Subnets, NSGs, internal load balancers, private endpoint, uploader VM
make network

# 3. Render install-config.yaml
make install-config

# 4. Create manifests, remove Machine API manifests, and create ignition
make ignition

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

Approve worker CSRs until nodes become ready:

```bash
while true; do
  oc get csr -o json \
    | jq -r '.items[] | select(.status == {}) | .metadata.name' \
    | xargs -r oc adm certificate approve
  sleep 20
done
```

Wait for completion:

```bash
./openshift-install --dir=install wait-for install-complete --log-level=info
```

## Post-install: ingress on a pre-created internal LB

This repo's Terraform pre-creates an internal apps load balancer
(`lb-ingress-internal-*`) in `terraform/01-network/` and puts workers in
its backend pool. The default `IngressController` is type
`LoadBalancerService`, which makes the cluster try to create a *second*
LB on top of the pre-created one — they conflict and `*.apps` routes
never resolve.

The fix is to patch the IngressController to `HostNetwork`, so it binds
directly to ports 80/443 on the worker nodes that sit behind the
pre-created LB. Run this **after** `wait-for install-complete` succeeds:

```bash
make ingress-hostnetwork
```

The target deletes the default IngressController and recreates it with
`endpointPublishingStrategy: HostNetwork`. After ~1-2 minutes the
ingress operator reports Available=True and `*.apps.<basedomain>`
resolves through the pre-created LB.

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

## Multus macvlan validation

Check the secondary worker NIC name first:

```bash
oc get nodes -l node-role.kubernetes.io/worker -o name \
  | xargs -I{} oc debug {} -- chroot /host ip -br a
```

If the secondary NIC is not `eth1`, update `manifests/multus/01-macvlan-nad.yaml`.
On arm64 (Ampere Altra) the secondary NIC is usually named `enP*s1` — see
[`docs/arm64-gotchas.md`](./docs/arm64-gotchas.md).

Apply the demo. The namespace manifest **must be applied first** — it sets
the `pod-security.kubernetes.io/enforce: privileged` labels that the
macvlan CNI needs on OpenShift 4.14+ (default profile is `restricted`).
We also need to grant the default service account access to the
`privileged` SCC, the same step we do for the SR-IOV demo:

```bash
oc apply -f manifests/multus/00-namespace.yaml
oc adm policy add-scc-to-user privileged -z default -n multus-demo
oc apply -f manifests/multus/01-macvlan-nad.yaml
oc apply -f manifests/multus/02-dualnic-pod.yaml
oc -n multus-demo rollout status deploy/dualnic --timeout=5m
oc -n multus-demo exec deploy/dualnic -- ip -br a
```

See [`manifests/multus/README.md`](./manifests/multus/README.md) for the
full validation walk-through and cleanup steps.

## Host-device / SR-IOV-style validation

The optional SR-IOV-style worker uses Azure Accelerated Networking and Multus host-device CNI to move a dedicated NIC into a pod network namespace.

Before applying the manifests:

1. Confirm the SR-IOV-style worker is Ready.
2. Confirm the dedicated NIC name inside RHCOS, default `eth2`.
3. Confirm the static IP in `manifests/sriov/01-hostdevice-nad.yaml` matches the Azure-assigned NIC IP.

```bash
oc label node <sriov-worker-node> sriov.demo/capable=true
oc apply -f manifests/sriov/00-namespace.yaml
oc adm policy add-scc-to-user privileged -z default -n sriov-demo
oc apply -f manifests/sriov/01-hostdevice-nad.yaml
oc apply -f manifests/sriov/02-demo-pod.yaml
oc -n sriov-demo wait --for=condition=Available deploy/sriov-demo --timeout=180s
oc -n sriov-demo logs deploy/sriov-demo
```

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
runbook in [`OPERATIONS.md`](./OPERATIONS.md) covers:

- `make etcd-backup` — snapshot etcd before any risky operation.
- `make cluster-shutdown` — Red Hat graceful shutdown then `az vm deallocate`.
- `make cluster-startup` — boot, auto-approve kubelet CSRs, uncordon, wait healthy.
- `make workers-down` / `make workers-up` — keep the control plane up and pause workers only.

For unattended scheduled runs (overnight shutdown / morning startup via
GitHub Actions, Linux cron, or systemd timers) see [`SCHEDULING.md`](./SCHEDULING.md).
For Azure-native alternatives when GitHub Actions isn't an option (Azure
Container Apps Jobs, Azure Automation + Linux Hybrid Worker, Functions,
Azure DevOps Pipelines) see [`AZURE-AUTOMATION.md`](./AZURE-AUTOMATION.md).
For the full CLI reference of every lifecycle script see
[`docs/scripts/`](./docs/scripts/).

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
   demo. See [`docs/arm64-gotchas.md`](./docs/arm64-gotchas.md).
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
   must add the proxy CA chain to `install-config.yaml` via
   `additionalTrustBundle` and set `httpsProxy` / `noProxy` correctly.
   Otherwise the bootstrap node will hang trying to pull RHCOS or
   release images. See `docs/proxy-and-tls-inspection.md` (added in a
   separate PR) for the noProxy template.
4. **Image-registry storage.** The image-registry operator tries to
   create its backing storage account by default. Tenant policies that
   block shared-key auth (`allowSharedKeyAccess=false`) will leave the
   operator in `Available=False, Degraded=True`. See
   `docs/image-registry-options.md` for the three workarounds (Removed,
   AAD/MI auth, pre-created storage account).
5. **Ingress LoadBalancerService vs pre-created internal LB.** If you
   pre-create an internal apps LB in Terraform, the default
   `IngressController` (LoadBalancerService type) will conflict and the
   `*.apps` route will not work until you patch the IngressController to
   `HostNetwork`. See the post-install ingress step in DEMO.md (added in
   a separate PR).
6. **Lifecycle scripts need `oc` on PATH and an active `az`.** After
   `make tools`, copy `./oc` to a PATH location (or `export PATH=$PWD:$PATH`),
   and ensure `az` is logged in (or set
   `AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET`/`AZURE_TENANT_ID` for SP-auth
   in non-interactive contexts). See the `require_oc` / `require_az`
   helpers in `scripts/lib/common.sh`.
