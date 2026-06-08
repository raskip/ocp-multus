# CNF storage: do we need a storage account, and how do workers access it?

Short answer:

| Need | Storage account? | How the worker reaches it |
|------|------------------|---------------------------|
| **RWO** (single-writer block) | **No** | Azure **managed disk** is attached to the worker VM as a data disk (block device); kubelet mounts it into the pod. |
| **RWX** (shared, multi-writer) | **Yes** | Pod mounts an **Azure Files** share over **SMB (TCP 445)** or **NFS 4.1 (TCP 2049)**, ideally via a **private endpoint** in the cluster VNet. |
| **RWX, high performance** | NetApp account (not a regular SA) | **Azure NetApp Files** over NFS, via a **delegated subnet**. |

## RWO — Azure Disk CSI (`disk.csi.azure.com`) — no storage account

Azure *managed disks* are standalone resources, **not** part of a storage
account. The Disk CSI **controller** calls the Azure API to create a managed
disk in the workload resource group, Azure attaches it to the worker VM, and the
CSI **node plugin** mounts it into the pod. RWO = one node at a time.

This works on this repo's **default** identity model with **no extra Azure
infra**: the install has no `credentialsMode`, so the Cloud Credential Operator
runs in **mint mode** and the install service principal (which has
**Contributor on the workload RG** — see
[`docs/azure-credentials.md`](../../docs/azure-credentials.md) /
[`docs/azure-identity-options.md`](../../docs/azure-identity-options.md) E2)
auto-provisions the CSI driver's credentials. Just apply
[`10-sc-azuredisk-rwo.yaml`](./10-sc-azuredisk-rwo.yaml).

## RWX — Azure Files CSI (`file.csi.azure.com`) — yes, needs a storage account

Azure Files lives in a storage account, so RWX needs one. **The storage account
this repo already creates in `00-prereqs` is NOT reusable** for this — it is
locked down for the install only (`public_network_access_enabled = false`,
`shared_access_key_enabled = false`, used for ignition/RHCOS blobs). You need a
**separate workload storage account**.

Two ways to provide it:

1. **Dynamic (default in [`20-sc-azurefile-rwx.yaml`](./20-sc-azurefile-rwx.yaml)):**
   the File CSI driver auto-creates a storage account + share on demand. Simple,
   but the auto-created account is public + key-based by default. A locked-down
   telco tenant's Azure Policy often blocks public storage accounts → dynamic
   provisioning then fails.

2. **BYO + private endpoint (recommended for locked-down tenants):** pre-create a
   dedicated workload storage account with a **private endpoint** in the cluster
   VNet (this repo already has the PE + private-DNS pattern at
   `terraform/01-network/main.tf`), then point the StorageClass at it via
   `storageAccount` / `resourceGroup` / `server`. Prefer **NFS 4.1** (no account
   keys, network-secured) for telco workloads.

### How the worker actually reaches an RWX share

- **SMB 3.0:** the pod mounts `//<sa>.file.core.windows.net/<share>` over **TCP
  445** using the storage-account key, which the CSI node plugin stores in a
  Kubernetes secret. Keep the traffic on the **private endpoint** (445 works
  intra-VNet; it is frequently blocked to the public internet).
- **NFS 4.1:** the pod mounts over **TCP 2049**. NFS has **no public endpoint**,
  so a **private endpoint is mandatory**, and it uses **no keys** (secured by the
  network). This is the cleanest option for a locked-down CNF deployment.
- **Azure NetApp Files:** highest throughput/lowest latency RWX. Needs a separate
  **NetApp account + capacity pool** and a **delegated subnet**; uses the ANF CSI.

## Optional Terraform for BYO RWX (`create_cnf_storage`)

For option 2 (or ANF) the repo would add a small, default-OFF Terraform block
(toggle `create_cnf_storage`) that creates the dedicated workload storage account
+ file share + private endpoint + private-DNS A record (reusing the existing PE
pattern), or the ANF account + delegated subnet. This is **not built yet** — it
depends on the SMB-vs-NFS-vs-ANF decision (TODO(vendor)). Until then, BYO the
account out-of-band and fill in the StorageClass params.

## Apply

```bash
# Confirm the CSI drivers are present (default in OCP 4.18 on Azure):
oc get csidrivers | grep -E 'disk.csi.azure.com|file.csi.azure.com'

oc apply -f 10-sc-azuredisk-rwo.yaml
oc apply -f 20-sc-azurefile-rwx.yaml   # edit for BYO/NFS first if needed
```

## TODO(vendor)

- RWX transport: SMB vs NFS 4.1 vs Azure NetApp Files.
- Required capacity tier / IOPS / throughput.
- Whether public storage-account creation is allowed, or BYO + private endpoint
  is mandatory (drives whether `create_cnf_storage` Terraform is needed).
- Whether one StorageClass should be the cluster default.
