# Architecture (ASCII)

Plain-text companion to [`architecture.md`](./architecture.md).

```text
Public DNS parent zone
  |
  +-- delegated OpenShift base domain

Existing Azure VNet
  |
  +-- snet-ocp-master       control plane + API internal LB
  +-- snet-ocp-worker       worker primary NICs + ingress internal LB
  +-- snet-ocp-bootstrap    bootstrap VM + uploader VM
  +-- snet-ocp-multus       worker secondary NICs for macvlan demo
  +-- snet-ocp-sriov        optional dedicated accelerated NIC

OpenShift resource group
  |
  +-- private storage account
  |     +-- ignition container
  |     +-- rhcos container
  |
  +-- private endpoint for blob storage
  +-- internal API/MCS load balancer
  +-- internal ingress load balancer
  +-- bootstrap VM
  +-- 3 control-plane VMs
  +-- worker VMs
  +-- optional host-device validation worker
```

Terraform creates Azure infrastructure. `openshift-install` creates OpenShift manifests and ignition configs. Machine API manifests are removed before ignition generation because Terraform creates the Azure VMs.

## OpenShift cluster view (pods, NADs, nodes)

```text
Worker node
  |
  +-- eth0  primary NIC      pod CIDR (OVN-Kubernetes)
  +-- eth1  secondary NIC    Multus subnet  (parent for macvlan)
  +-- eth2  optional NIC     Accelerated Networking
                             (moved into one pod via host-device CNI)

Default-network pod
  |
  +-- eth0 only (OVN overlay -> NAT egress on node eth0)

macvlan demo pod
  |
  +-- eth0    (default network, OVN)
  +-- net1    (macvlan child of eth1, IP from Multus subnet)

host-device demo pod
  |
  +-- eth0    (default network, OVN)
  +-- net1    (== eth2 moved into pod netns; host no longer owns it)
```

Namespace `multus-demo` must have the
`pod-security.kubernetes.io/enforce: privileged` label so the macvlan /
host-device CNI plugins can attach to host NICs.

## Data-path contrast

```text
                       +----------------------+
default CNI            | pod -> OVS br-int    |  Geneve overlay,
(OVN-Kubernetes)       |     -> node netns    |  egress NAT on eth0
                       +----------------------+

                       +----------------------+
macvlan (Multus)       | pod net1 -> eth1     |  no encap, no NAT
                       |  (NIC shared)        |  pod has its own IP in VNet
                       +----------------------+

                       +----------------------+
host-device (Multus)   | pod net1 == eth2     |  no encap, no NAT
                       |  (NIC owned by pod)  |  one pod per NIC
                       +----------------------+
```

## macvlan vs host-device summary

| Concern               | macvlan                     | host-device                 |
|-----------------------|-----------------------------|-----------------------------|
| Encapsulation         | none                        | none                        |
| NIC shared with node  | yes                         | no (moved into pod netns)   |
| Pods per node         | many                        | one (per dedicated NIC)     |
| Best for              | secondary-NIC workloads     | latency-/throughput-sensitive |

## Why host-device — not the SR-IOV Operator

Azure VM SR-IOV is exposed as Accelerated Networking. There is no
PCI-passthrough surface inside the guest, so the SR-IOV Operator's
value (VF discovery, NIC partitioning, DPDK driver binding) can't be
exercised on Azure VM nodes. Multus host-device CNI moves a whole NIC
into a pod's network namespace, which gives the same line-rate /
no-encap data path with much less operational complexity. See
[architecture.md](./architecture.md) for the mermaid version of this
view.
