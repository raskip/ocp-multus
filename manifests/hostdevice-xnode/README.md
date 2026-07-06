# Cross-node host-device Multus demo

Demonstrates the common requirement:

> a pod keeps its **default `eth0`** (cluster network + OpenShift ingress) **and**
> gets a **second interface** that is routable for **external / cross-node**
> connectivity.

This is the Azure-native answer to the limitation called out in
[`../../docs/multus-validation.md`](../../docs/multus-validation.md): the macvlan
demo only works **same-node** on Azure, because macvlan assigns a *synthetic* MAC
that Azure's SDN drops. **host-device** instead moves a **real Azure NIC**
(registered MAC + Azure-assigned IP) into the pod, so Azure routes it natively
across nodes and out to the VNet.

## What it uses

The standard worker pool (`CNF_PROFILE=false`) already gives each worker a
secondary NIC on the Multus subnet — in-guest **`eth1`**. No infrastructure
change, no extra subnet, and no worker rebuild are required.

The demo moves each worker's `eth1` into **one pod on that node** (host-device is
one pod per NIC, per node), then pings **across nodes** over those real NICs.

```
pod hostdev-a (worker A)                 pod hostdev-b (worker B)
  eth0  default pod network                eth0  default pod network
  net1  = worker A eth1 (real Azure NIC)   net1  = worker B eth1 (real Azure NIC)
        \___________ cross-node ping over the Azure VNet ___________/
```

## Prerequisites

- Cluster install complete; `oc` can reach the API.
- At least **two** worker nodes, each with the Multus secondary NIC
  (default pool, `CNF_PROFILE=false`).
- Confirm the in-guest NIC name (usually `eth1`; arm64 uses `enP*`):

  ```bash
  oc get nodes -l node-role.kubernetes.io/worker -o name \
    | xargs -I{} oc debug {} -- chroot /host ip -br a
  ```

## Reference manifests (read these to see the shape)

If you prefer to see/apply the YAML directly instead of the script, the
[`example/`](./example/) directory has annotated reference manifests:

| File | What it shows |
|------|---------------|
| [`example/00-namespace.yaml`](./example/00-namespace.yaml) | Namespace with the required privileged Pod Security labels. |
| [`example/01-hostdevice-nad.yaml`](./example/01-hostdevice-nad.yaml) | Two host-device NADs (one per node). Each pins `device: eth1` and a static IP = that node's Azure-assigned NIC IP. |
| [`example/02-dualnic-pod.yaml`](./example/02-dualnic-pod.yaml) | Two dual-NIC pods (`eth0` + `net1`), one pinned to each worker via `nodeName`, attaching the secondary interface through the `k8s.v1.cni.cncf.io/networks` annotation. |

These carry **placeholder** IPs / node names (see the `TODO` comments) — replace
them with your live values, then:

```bash
oc apply -f manifests/hostdevice-xnode/example/00-namespace.yaml
oc apply -f manifests/hostdevice-xnode/example/01-hostdevice-nad.yaml
oc apply -f manifests/hostdevice-xnode/example/02-dualnic-pod.yaml
```

The **key line** for attaching extra interfaces is the pod annotation
`k8s.v1.cni.cncf.io/networks: <nad-name>` — add more NADs comma-separated to
attach more interfaces.

## Run (automated)

```bash
./manifests/hostdevice-xnode/run-demo.sh
```

The script auto-discovers the two worker nodes and each node's `eth1` IP,
generates the namespace + two host-device NADs (static IPAM pinned to each
node's Azure-assigned IP) + two pods (one per node), waits, and runs the
cross-node ping. **Success = the ping replies.**

### Options (environment variables)

| Var | Default | Purpose |
|-----|---------|---------|
| `OC` | `oc` | Path to the `oc` binary (e.g. `./oc`). |
| `NS` | `hostdev-xnode-demo` | Demo namespace. |
| `DEV` | `eth1` | In-guest name of the Multus-subnet NIC (arm64: `enP*`). |
| `NODE_A`, `NODE_B` | first two workers | Pin specific worker nodes. |
| `GW` | *(empty)* | Optional gateway for an external-egress ping. |

Example:

```bash
OC=./oc DEV=eth1 GW=10.0.0.1 ./manifests/hostdevice-xnode/run-demo.sh
```

## Why static IPAM must equal the Azure-assigned IP

host-device gives the moved NIC whatever IP the CNI IPAM assigns. The script sets
`type: static` to the NIC's **existing Azure-assigned IP** (read live from the
node) so Azure's SDN does not filter source-IP-mismatched traffic. Do not invent
an arbitrary IP here.

## Cleanup

```bash
oc delete ns hostdev-xnode-demo
```

## When to use something else

- **Many pods** sharing an external NIC (not one-per-node): use **ipvlan**
  (parent NIC's real MAC, multiple children). See the CNF/telco profile in
  [`../../docs/cnf-telco-profile.md`](../../docs/cnf-telco-profile.md) and
  [`../cnf/`](../cnf/).
- **Same-node** secondary networking only: the macvlan demo in
  [`../multus/`](../multus/) is sufficient.
