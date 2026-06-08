# Optional CNF / telco profile

This profile layers a telco CNF topology (e.g. AUSF/UDM + HSS/HLR) on top
of the base UPI install. It is **additive, toggle-gated (`CNF_PROFILE` /
`enable_cnf_lans`), BYO-network compatible, and defaults OFF** — existing users
see no change. It does not rewrite the base install; it adds dedicated LAN
subnets, per-LAN worker NICs with Accelerated Networking, Multus ipvlan
networks, node tuning, storage classes, and an optional bastion.

> **Several manifests ship as templates with `TODO(vendor)` placeholders.** The
> Terraform spine (subnets + worker NICs) builds against placeholder CIDRs now;
> the workload/tuning manifests need the CNF vendor's exact values before they
> route and tune correctly. See the per-directory READMEs.

## What you need to provide (prerequisites)

Before enabling `CNF_PROFILE=true`, confirm these inputs with your network,
storage, platform, and CNF vendor teams:

- **A correctly sized and hub-peered VNet.** A `/21` is the comfortable baseline
  for the base cluster, default Multus, optional SR-IOV, and the three CNF LANs;
  see [`network-prereqs.md`](./network-prereqs.md#2-subnet-sizing) and the
  [VNet peering guidance](./network-prereqs.md#6-vnet-peering).
- **The three LAN CIDRs** for OAM, AUSF-UDM, and HSS-HLR. These become
  `snet-ocp-oam`, `snet-ocp-ausfudm`, and `snet-ocp-hsshlr`.
- **The CNF vendor network values** listed in
  [Vendor values to confirm before `make cnf-apply`](#vendor-values-to-confirm-before-make-cnf-apply).
- **A storage decision** for RWX: Azure Files or Azure NetApp Files. RWO uses
  Azure Disk; see [Components](#components) for the storage manifests.
- **A registry decision:** in-cluster ImageStream support via the managed image
  registry, or an external enterprise registry such as ACR.
- **Firewall egress** from the worker external LANs to the CNF peers and services
  that the vendor requires.
- **MTU and throughput on the path:** target a consistent 1500 MTU end-to-end and
  validate approximately 400 MB/s on the relevant CNF data path. See [MTU](#mtu).

## What it adds

| Area | Off (default) | On (`CNF_PROFILE=true`) |
|------|---------------|--------------------------|
| Subnets | master/worker/bootstrap/multus; SR-IOV only with `ENABLE_SRIOV=true` | + `snet-ocp-oam` (/28), `snet-ocp-ausfudm` (/26), `snet-ocp-hsshlr` (/26) |
| Worker NICs | primary + demo multus (2 NICs) | primary + OAM + AUSF-UDM + HSS-HLR (4 NICs); demo multus NIC dropped |
| Accelerated Networking | off | on (primary + LAN NICs) — accelerates TCP/UDP, **not SCTP** |
| Worker SKU | `D4s_v5` (2 NIC slots) | `D8s_v5` (4 NIC slots) |
| Image registry | Removed | Managed (ImageStreams) |
| Extras | — | optional Linux bastion; RWO/RWX StorageClasses; node tuning; CNF pool/SCC |

## Enable + deploy (easy path)

The profile is opt-in and remains off unless `CNF_PROFILE=true` is set.

1. Enable the profile and deploy the Azure infrastructure with the normal runbook:

   ```bash
   # in config/cluster.env
   CNF_PROFILE=true

   make all
   ```

   This automates the three LAN subnets, per-LAN worker NICs, Accelerated
   Networking, the D8s_v5 worker size, and the optional Linux bastion when its
   toggle is enabled.

2. Run the read-only preflight before changing cluster objects:

   ```bash
   make cnf-preflight
   ```

   The preflight checks that `oc` is logged in, `CNF_PROFILE=true` is set,
   appworkers have four NICs, the three CNF subnets exist, manifests are present,
   and the vendor placeholders have been reviewed.

3. Fill the [vendor checklist](#vendor-values-to-confirm-before-make-cnf-apply),
   then apply the post-install profile:

   ```bash
   make cnf-apply
   ```

   By default this prints a summary, reminds you to confirm the vendor values,
   and asks for interactive confirmation before applying.

4. Verify the finished profile:

   ```bash
   make cnf-verify
   ```

   Verification is read-only. It checks that the `appworker` MCP is converged,
   nodes are labeled with four NICs in the expected order
   (`eth0` primary, `eth1` OAM, `eth2` AUSF-UDM, `eth3` HSS-HLR), the three
   ipvlan NADs exist, RWO/RWX StorageClasses exist, and the image registry is
   `Managed`.

## Safety flags for CNF make targets

- `CNF_YES=1 make cnf-apply` skips the interactive confirmation prompt.
- `DRY_RUN=1 make cnf-apply` previews the planned post-install sequence without
  applying resources.
- `CNF_NODES="node-a node-b" make cnf-apply` overrides automatic worker-node
  detection for the node-labeling step.

## Vendor values to confirm before `make cnf-apply`

Confirm every `TODO(vendor)` value before running `make cnf-apply`; otherwise the
manifests may apply but the CNF may not route, schedule, or tune correctly.

- **ipvlan mode per LAN:** `l2`, `l3`, or `l3s` for OAM, AUSF-UDM, and HSS-HLR.
- **IPAM per LAN:** range, gateway, and allocation method for each LAN. Ensure
  pod IP ranges do not overlap Azure-assigned NIC IPs.
- **Static routes per LAN:** required routes for OAM, AUSF-UDM, and HSS-HLR to
  reach CNF peers and external services.
- **Master NIC mapping per LAN:** default mapping is `eth1`=OAM,
  `eth2`=AUSF-UDM, `eth3`=HSS-HLR; verify actual ordering before go-live. See
  [NIC ordering (gotcha)](#nic-ordering-gotcha).
- **Kernel parameters and sysctls:** additional kernel args, the
  `cni-sysctl-allowlist` entries to merge with cluster defaults, and the
  `allowedUnsafeSysctls` list for the `appworker` pool.
- **THP policy:** confirm whether `madvise` is correct or whether the CNF vendor
  requires a different Transparent Huge Pages setting.
- **Pod security and scheduling:** required Linux capabilities, any host access or
  host ports, and the required PriorityClass value/preemption policy.
- **LAN and external firewall policy:** LAN CIDRs, external peer CIDRs, protocols,
  and ports that must be reachable from the worker external LANs.
- **RWX backend:** Azure Files or Azure NetApp Files, including protocol,
  capacity, throughput, private endpoint/delegated subnet needs, and whether one
  StorageClass should be default.
- **Registry requirement:** whether the in-cluster managed image registry and
  ImageStreams are mandatory, or whether an external enterprise registry is
  acceptable.

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
- Re-run `make cnf-preflight` before changing vendor values, then use
  `DRY_RUN=1 make cnf-apply` to preview the resulting apply sequence.

## Under the hood (what `cnf-apply` runs)

`make cnf-apply` wraps the formerly manual post-install sequence below. It uses
`oc apply`, so it is safe to re-run after correcting inputs.

```bash
# 1. Namespace
oc apply -f manifests/cnf/00-namespace.yaml

# 2. CNF platform objects: appworker pool, ServiceAccount, scoped SCC, PriorityClass
oc apply -f manifests/cnf-platform/

# 3. Label appworker nodes. Auto-detected by default; override with CNF_NODES.
scripts/label-cnf-nodes.sh
# CNF_NODES="node-a node-b" scripts/label-cnf-nodes.sh

# 4. Wait for the appworker MachineConfigPool to converge
oc get mcp appworker -w

# 5. Node tuning: SCTP, THP, sysctls (requires confirmed vendor values)
oc apply -f manifests/node-tuning/

# 6. CNF ipvlan NADs and example workload namespace assets
oc apply -f manifests/cnf/

# 7. StorageClasses: RWO + selected RWX backend
oc apply -f manifests/storage/

# 8. Keep the in-cluster image registry Managed for ImageStreams
scripts/configure-image-registry-managed.sh
```
