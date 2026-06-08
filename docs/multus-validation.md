# Multus secondary-network validation

This repo provisions Azure infrastructure that supports Multus
validation patterns:

- **macvlan**, on the worker pool's secondary NIC (`snet-ocp-multus`).
- **host-device / SR-IOV-style**, on an opt-in dedicated worker that
  uses Azure Accelerated Networking (`ENABLE_SRIOV=true`).

Both demos are **optional** — they validate that secondary pod networking
is wired correctly end-to-end. Skip them if the cluster is for a workload
that does not need additional pod NICs.

> For a production telco CNF topology (ipvlan NADs per LAN, SCTP, node tuning,
> dedicated per-LAN worker NICs, RWX storage), see the optional
> [`cnf-telco-profile.md`](./cnf-telco-profile.md) — it builds on the same Multus
> foundation as these demos.

Run them after the cluster has finished installing (`make all` completed,
`oc get nodes` shows all workers `Ready`).

## Prerequisites

1. Cluster install complete (`openshift-install wait-for install-complete`
   returned success).
2. `KUBECONFIG` points at the new cluster (`source ./bin/env.sh`).
3. The expected Multus subnet (`snet-ocp-multus`) exists and each worker
   has a second NIC attached to it. Verify:

   ```bash
   oc get nodes -l node-role.kubernetes.io/worker -o name \
     | xargs -I{} oc debug {} -- chroot /host ip -br a
   ```

   On x86_64 the secondary NIC is usually `eth1`. On arm64
   (Ampere Altra `Standard_D*ps_v5`) it is typically `enP*s1` — see
   [`arm64-gotchas.md`](./arm64-gotchas.md).

## Why the explicit SCC + PodSecurity steps

The macvlan / host-device CNI plugins run inside the pod's network
namespace and must have `NET_ADMIN` + `NET_RAW` capabilities. Combined
with the secondary-NIC attachment, this requires the **`privileged` SCC**
and the **`privileged` Pod Security profile** on the demo namespace.

On OpenShift 4.14+ the default admission profile is `restricted`, so the
demo namespace must set the enforce/audit/warn labels to `privileged`
explicitly. The `00-namespace.yaml` manifests already include them; if
you re-render or modify those manifests, keep the
`pod-security.kubernetes.io/*` labels intact or the macvlan/host-device
CNI will fail with `admission webhook "pod-security.kubernetes.io..."
denied`.

## macvlan demo

The macvlan NAD attaches a virtual interface on top of the worker's
secondary NIC and assigns pod IPs from the Whereabouts IPAM range.

1. Confirm or edit the secondary NIC name in
   `manifests/multus/01-macvlan-nad.yaml` (`master` field).
2. Confirm the Whereabouts IPAM range in `01-macvlan-nad.yaml` is inside
   your Multus subnet and does not overlap Azure-assigned NIC IPs. The
   default example uses the `10.20.2.0/23` range, with pod secondary
   addresses from `10.20.3.1`–`10.20.3.254` and gateway `10.20.2.1`.
   The lower `/24` of that range is reserved for Azure-assigned worker
   NIC IPs.
3. Apply the manifests. The namespace **must be applied first** — it
   sets the PodSecurity labels:

   ```bash
   oc apply -f manifests/multus/00-namespace.yaml
   oc adm policy add-scc-to-user privileged -z default -n multus-demo
   oc apply -f manifests/multus/01-macvlan-nad.yaml
   oc apply -f manifests/multus/02-dualnic-pod.yaml
   ```

4. Verify:

   ```bash
   oc -n multus-demo rollout status deploy/dualnic --timeout=5m
   oc -n multus-demo get pods -o wide
   oc -n multus-demo exec deploy/dualnic -- ip -br a
   ```

   The pod should show its primary cluster-network NIC plus a second NIC
   in the Whereabouts range.

### Cleanup

```bash
oc delete -f manifests/multus/02-dualnic-pod.yaml
oc delete -f manifests/multus/01-macvlan-nad.yaml
oc delete -f manifests/multus/00-namespace.yaml
```

## Host-device / SR-IOV-style demo

The SR-IOV-style worker uses Azure Accelerated Networking and the
Multus **host-device** CNI to move a dedicated NIC into a pod network
namespace. This is the closest you can get to SR-IOV on stock Azure
VMs without the SR-IOV Operator.

This demo is only useful if the `terraform/05-workers` stack provisioned
the optional SR-IOV-style worker. It is off by default; opt in with
`ENABLE_SRIOV=true` in `config/cluster.env` (`enable_sriov` in tfvars).

1. Confirm the SR-IOV-style worker is Ready.
2. Confirm the dedicated NIC name inside RHCOS (default `eth2`):

   ```bash
   oc debug node/<sriov-worker> -- chroot /host ip -br a
   ```

3. Confirm the static IP in `manifests/sriov/01-hostdevice-nad.yaml`
   matches the Azure-assigned NIC IP for that interface.
4. Apply:

   ```bash
   oc label node <sriov-worker-node> sriov.demo/capable=true
   oc apply -f manifests/sriov/00-namespace.yaml
   oc adm policy add-scc-to-user privileged -z default -n sriov-demo
   oc apply -f manifests/sriov/01-hostdevice-nad.yaml
   oc apply -f manifests/sriov/02-demo-pod.yaml
   oc -n sriov-demo wait --for=condition=Available deploy/sriov-demo --timeout=180s
   oc -n sriov-demo logs deploy/sriov-demo
   ```

### Cleanup

```bash
oc delete -f manifests/sriov/02-demo-pod.yaml
oc delete -f manifests/sriov/01-hostdevice-nad.yaml
oc delete -f manifests/sriov/00-namespace.yaml
oc label node <sriov-worker-node> sriov.demo/capable-
```

## Where to go next

- [`../manifests/multus/README.md`](../manifests/multus/README.md) —
  manifest-level reference (file-by-file walkthrough of the macvlan NAD,
  Whereabouts IPAM config, and dualnic pod spec).
- [`../manifests/sriov/README.md`](../manifests/sriov/README.md) —
  manifest-level reference for the host-device demo.
- [`arm64-gotchas.md`](./arm64-gotchas.md) — NIC naming + RHCOS quirks
  on Ampere Altra hosts.
- [`network-prereqs.md`](./network-prereqs.md) — subnet sizing
  requirements for the Multus secondary subnet when using BYO networking.
