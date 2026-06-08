# Optional CNF / telco profile

This profile layers a telco CNF topology (e.g. AUSF/UDM + HSS/HLR) on top
of the base UPI install. It is **additive, toggle-gated (`CNF_PROFILE` /
`enable_cnf_lans`), BYO-network compatible, and defaults OFF** — existing users
see no change. It does not rewrite the base install; it adds dedicated LAN
subnets, per-LAN worker NICs with Accelerated Networking, Multus ipvlan
networks, node tuning, storage classes, and an optional bastion.

> **Several manifests ship as templates with `TODO(vendor)` placeholders.** The
> Terraform spine (subnets + worker NICs) builds against placeholder CIDRs now;
> the workload/tuning manifests need the vendor's exact values before they route
> and tune correctly. See the per-directory READMEs.

## What it adds

| Area | Off (default) | On (`CNF_PROFILE=true`) |
|------|---------------|--------------------------|
| Subnets | master/worker/bootstrap/multus; SR-IOV only with `ENABLE_SRIOV=true` | + `snet-ocp-oam` (/28), `snet-ocp-ausfudm` (/26), `snet-ocp-hsshlr` (/26) |
| Worker NICs | primary + demo multus (2 NICs) | primary + OAM + AUSF-UDM + HSS-HLR (4 NICs); demo multus NIC dropped |
| Accelerated Networking | off | on (primary + LAN NICs) — accelerates TCP/UDP, **not SCTP** |
| Worker SKU | `D4s_v5` (2 NIC slots) | `D8s_v5` (4 NIC slots) |
| Image registry | Removed | Managed (ImageStreams) |
| Extras | — | optional Linux bastion; RWO/RWX StorageClasses; node tuning; CNF pool/SCC |

## Prerequisites — values to get from the CNF vendor

ipvlan mode (l2/l3/l3s) + IPAM/gateways/static routes per LAN; exact kernel
params + sysctls (CNI allowlist + unsafe) + THP policy; required pod
capabilities + PriorityClass; LAN + external CIDRs/ports; whether 400 MB/s is
per-worker and TCP/UDP vs SCTP; RWX = Azure Files (SMB/NFS) vs ANF; whether the
in-cluster registry is mandatory or external Quay/ACR is acceptable. (See the
workshop questions in the session deliverables.)

## Enable + deploy

1. Merge the preset into your config:

   ```bash
   cat config/cluster.cnf.example.env >> config/cluster.env
   # then edit config/cluster.env: set the real LAN CIDRs.
   ```

2. Render tfvars and apply the infra (same flow as the base runbook):

   ```bash
   make tfvars              # scripts/render-tfvars-from-env.sh
   make network            # 01-network: creates the 3 CNF LAN subnets
   # ... base install (image/bootstrap/control-plane) ...
   make workers            # 05-workers: 4 NICs/worker on D8s_v5 with AN
   AUTO_IMAGE_REGISTRY_REMOVED=false make wait-install
   ```

3. Post-install, apply the platform → tuning → workloads → storage manifests:

   ```bash
   oc apply -f manifests/cnf/00-namespace.yaml
   oc apply -f manifests/cnf-platform/          # pool, SA, scoped SCC, PriorityClass
   scripts/label-cnf-nodes.sh vm-worker-0-<cluster> vm-worker-1-<cluster>
   oc get mcp appworker -w                       # wait for the pool to converge
   oc apply -f manifests/node-tuning/            # SCTP/THP/sysctls (TODO(vendor))
   oc apply -f manifests/cnf/                     # ipvlan NADs + example pod (TODO(vendor))
   oc apply -f manifests/storage/                # RWO + RWX StorageClasses
   scripts/configure-image-registry-managed.sh   # registry -> Managed
   ```

## Components

- **Networking + workers (Terraform):** `terraform/01-network` (subnets) and
  `terraform/05-workers` (NICs + SKU + AN), gated by `enable_cnf_lans`.
- **ipvlan networks:** [`manifests/cnf/`](../manifests/cnf/) — one NAD per LAN.
- **Node tuning:** [`manifests/node-tuning/`](../manifests/node-tuning/) — SCTP
  module, THP, sysctls, scoped to the `appworker` pool.
- **CNF pool / SCC / priority:** [`manifests/cnf-platform/`](../manifests/cnf-platform/).
- **Storage:** [`manifests/storage/`](../manifests/storage/) — RWO (Azure Disk,
  no storage account) + RWX (Azure Files; needs a storage account — see that
  README for the SMB/NFS/ANF + private-endpoint detail).
- **Registry:** [`image-registry-options.md`](./image-registry-options.md) →
  CNF profile note + `scripts/configure-image-registry-managed.sh`.
- **Bastion:** `create_linux_bastion` in `terraform/01-network`.

## NIC ordering (gotcha)

With the profile on, each worker has 4 NICs. In-guest order is
`eth0`=primary, `eth1`=OAM, `eth2`=AUSF-UDM, `eth3`=HSS-HLR (PCI order; arm64
uses `enP*`). The ipvlan NADs reference these via `master:`. Always verify:

```bash
oc get nodes -l node-role.kubernetes.io/appworker -o name \
  | xargs -I{} oc debug {} -- chroot /host ip -br a
```

## MTU

Target an effective **1500** MTU end-to-end. The OVN pod-network overlay runs
~1400 (Geneve overhead) and is independent; the Multus secondary ipvlan NICs get
the full 1500. Validate the path MTU (no fragmentation) between CNF pods and
their external peers before go-live; optionally pin the secondary-interface MTU
in the NADs.

## Day-2 notes

- Accelerated Networking cannot be toggled on a running NIC without VM
  deallocation — enable it at build time (the profile does).
- Node-tuning MachineConfigs roll the `appworker` pool one node at a time.

## TODO(vendor) — consolidated

Tracked per directory; the must-have answers are: ipvlan mode + IPAM + routes;
kernel/sysctl/THP params; pod capabilities + PriorityClass; LAN + external
CIDRs/ports; 400 MB/s per-what and TCP/UDP vs SCTP; RWX transport (Files SMB/NFS
vs ANF) + whether public storage accounts are allowed; registry mandatory vs
external.
