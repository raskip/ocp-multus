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

Apply the demo:

```bash
oc apply -f manifests/multus/01-macvlan-nad.yaml
oc apply -f manifests/multus/02-dualnic-pod.yaml
oc -n multus-demo rollout status deploy/dualnic --timeout=5m
oc -n multus-demo exec deploy/dualnic -- ip -br a
```

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
