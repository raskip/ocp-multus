# Network prerequisites for BYO-network mode

This document is for the **network team** that will provision Azure
networking before an OpenShift Azure UPI install. It is vendor- and
tool-neutral: pick the resources, sizing, and rules below, and create
them with whichever IaC you already use (Terraform, Bicep, ARM,
Ansible, az CLI, or the portal).

When all the resources listed here exist, the OpenShift installer can
run in **BYO-network mode** (`manage_network_resources = false` in
`terraform/01-network/terraform.tfvars`) — it will only create the
cluster-specific load balancers, DNS records, the storage Private
Endpoint, and the helper VMs, and consume the rest by ID.

Runnable example scripts are in
[`examples/network-prereqs-azcli/`](../examples/network-prereqs-azcli/).

---

## 1. Resources required

| # | Resource | Required | Notes |
|---|---|---|---|
| 1 | Resource Group for shared networking | yes | Hosts the VNet, NSGs, route table. Separate from the workload RG that holds cluster VMs. |
| 2 | VNet | yes | Address space sized per section 2. |
| 3 | Subnet `snet-ocp-master` | yes | NSG attached, see section 3. |
| 4 | Subnet `snet-ocp-worker` | yes | NSG attached. Route table attached (egress). |
| 5 | Subnet `snet-ocp-bootstrap` | yes | NSG attached. Route table attached (egress). |
| 6 | Subnet `snet-ocp-multus` | optional | Only needed if Multus secondary NICs are used. NSG attached. |
| 7 | Subnet `snet-ocp-sriov` | optional | Only needed if SR-IOV / host-device CNI is used. NSG attached. |
| 8 | NSG for master subnet | yes | Section 3. |
| 9 | NSG for worker subnet | yes | Section 3. |
| 10 | Route table for egress (UDR) | yes (hub-spoke + FW egress) | Section 4. |
| 11 | VNet peering to hub (if applicable) | yes (hub-spoke) | Both directions, `allowForwardedTraffic = true`. |
| 12 | Private DNS zone `privatelink.blob.core.windows.net` | yes | Linked to the cluster VNet. Often centrally managed in a hub DNS RG. |
| 13 | Parent DNS zone for cluster API/apps | yes | Section 5. |

The cluster installer creates:
- Internal LBs `lb-api-internal-<cluster>` and `lb-ingress-internal-<cluster>`
- Private DNS zone `<cluster_name>.<base_domain>` (e.g. `lab.ocp.example.com`)
- Private DNS records `api`, `api-int`, `*.apps` inside that zone
- Storage Private Endpoint for the bootstrap/RHCOS storage account
- Uploader VM (Linux) and, only if `CREATE_WINDOWS_JUMP=true`, an
  optional Windows browser/RDP jump VM in the bootstrap subnet

> **DNS layout note (B62 fix).** Since the B62 fix, the cluster's private
> DNS zone is created with the cluster name as the leftmost label
> (`<cluster_name>.<base_domain>`) and records use short names. This is
> what `openshift-install`'s ingress-operator expects in order to manage
> the dynamic `*.apps` records itself; the legacy layout (zone named
> `<base_domain>`, records named `api.<cluster_name>` etc.) caused the
> install to hang at `wait-for install-complete`. Set
> `USE_LEGACY_DNS_LAYOUT=true` in `config/cluster.env` only when
> migrating an existing pre-fix cluster you cannot rebuild — switching
> layouts is a Terraform destroy + create of the zone resource.

---

## 2. Subnet sizing

| Subnet | Minimum | Recommended | Rationale |
|---|---|---|---|
| `snet-ocp-master` | /28 (16 IP) | **/27 (32 IP)** | 3 master VMs + ILB frontends + storage PE; count stays fixed at 3 masters |
| `snet-ocp-bootstrap` | /29 (8 IP) | **/28 (16 IP)** | 1 bootstrap VM (transient) + uploader VM + optional Windows jump VM (`CREATE_WINDOWS_JUMP=true`) |
| `snet-ocp-worker` | /28 (16 IP) | **/24 (256 IP)** | 2–N worker VMs + ingress ILB frontend; grows with workload |
| `snet-ocp-multus` | /25 (128 IP) | **/24 (256 IP)** | Pod IPs for whereabouts IPAM on macvlan / bridge NADs |
| `snet-ocp-sriov` | /28 (16 IP) | **/27 (32 IP)** | One VF IP per worker per host-device NIC + a few reserves |

A `/22` VNet (1024 addresses) leaves room for all five subnets at the
recommended sizes plus growth.

---

## 3. NSG rules

The defaults are deliberately permissive — they assume the cluster
spoke is firewalled at the perimeter (NSG enforces "what's allowed
into a subnet from inside the VNet", not "what can reach the cluster
from the internet"). Tighten as your tenant requires.

### Master subnet NSG (minimum inbound)

| # | Source | Source port | Destination port | Protocol | Action | Purpose |
|---|---|---|---|---|---|---|
| 1 | `VirtualNetwork` | * | 6443 | TCP | Allow | Cluster API |
| 2 | `VirtualNetwork` | * | 22623 | TCP | Allow | Machine Config Server |
| 3 | `<installer-host CIDR>` or `VirtualNetwork` | * | 22 | TCP | Allow | SSH (debug, uploader) |
| 4 | `VirtualNetwork` | * | 9000–9999 | TCP | Allow | etcd, controller-manager, scheduler |
| 5 | `VirtualNetwork` | * | 10250–10259 | TCP | Allow | kubelet, etcd-events |
| 6 | `AzureLoadBalancer` | * | * | * | Allow | LB health probes |

### Worker subnet NSG (minimum inbound)

| # | Source | Source port | Destination port | Protocol | Action | Purpose |
|---|---|---|---|---|---|---|
| 1 | `VirtualNetwork` | * | 80 | TCP | Allow | Apps HTTP ingress |
| 2 | `VirtualNetwork` | * | 443 | TCP | Allow | Apps HTTPS ingress |
| 3 | `VirtualNetwork` | * | 22 | TCP | Allow | SSH (debug) |
| 4 | `VirtualNetwork` | * | 10250–10259 | TCP | Allow | kubelet |
| 5 | `VirtualNetwork` | * | 30000–32767 | TCP | Allow | NodePort (if used) |
| 6 | `AzureLoadBalancer` | * | * | * | Allow | LB health probes |

Bootstrap, multus, and sriov subnets can reuse the worker NSG or
have minimal NSGs of their own.

The cluster's outbound side is governed by the route table (section 4)
and your firewall, not by NSGs.

---

## 4. Route table (UDR) for egress

When the spoke peers to a hub that holds a firewall NVA:

| # | Address prefix | Next hop type | Next hop IP | Purpose |
|---|---|---|---|---|
| 1 | `0.0.0.0/0` | `VirtualAppliance` | `<hub firewall private IP>` | Default egress to the internet via the firewall |
| (opt) | on-prem CIDRs | `VirtualNetworkGateway` | — | If ER/VPN is in the hub and the firewall forwards on-prem traffic |

**Attach this route table to** `snet-ocp-master`, `snet-ocp-worker`,
`snet-ocp-bootstrap`, and `snet-ocp-multus`. Failing to attach to
master/bootstrap leaks installer pull traffic past the firewall.
(In repo-managed mode, `attach_route_table_to_extra_subnets = ["master","bootstrap","multus"]` does this; in BYO mode the network
team attaches it.)

The cluster cloud-provider mutates routes on this table during install
to add per-node routes for the Kubernetes service network. The
identity used by the installer must therefore have **Network
Contributor** on the route table (or the resource group containing it).

See
[`required-outbound-destinations.md`](./required-outbound-destinations.md)
for the FQDN/IP allow-list the firewall must permit.

---

## 5. DNS

- **Parent zone** (e.g. `example.com`, or a sub-zone delegated to your
  team): pre-exists in Azure DNS. The installer's identity needs `DNS
  Zone Contributor` (or equivalent) on this zone so it can add an `NS`
  delegation for the cluster sub-zone.
- **Cluster sub-zone** (e.g. `ocp.example.com`): created by the
  installer in the workload RG. It contains `api`, `api-int`, and
  `*.apps` A-records pointing at the internal LB.
- **`privatelink.blob.core.windows.net` private DNS zone**:
  pre-exists, linked to the cluster spoke VNet. The installer adds an
  A-record for the storage Private Endpoint to this zone.

If you operate `Internal` ingress (`publish: Internal` in
`install-config.yaml`), on-prem clients reach the cluster API and apps
either via Azure Private DNS Resolver (inbound endpoint in the hub) +
on-prem conditional forwarder for the cluster sub-zone, or via a
jump host inside the VNet.

---

## 6. VNet peering

For hub-spoke topologies, create peerings in **both** directions:

| Direction | Setting | Required |
|---|---|---|
| Spoke → Hub | `allowVirtualNetworkAccess = true` | yes |
| Spoke → Hub | `allowForwardedTraffic = true` | yes (firewall NATs spoke traffic) |
| Spoke → Hub | `useRemoteGateways = true` | only if hub has ER/VPN gateway |
| Hub → Spoke | `allowVirtualNetworkAccess = true` | yes |
| Hub → Spoke | `allowForwardedTraffic = true` | yes |
| Hub → Spoke | `allowGatewayTransit = true` | only if hub has ER/VPN gateway |

Peering connection state must be `Connected` on both legs.

---

## 7. Validation

Before handing off to the OpenShift install team, verify:

```bash
# Subnets exist with the expected NSGs and (for worker/master/bootstrap/multus)
# the expected route table attached:
az network vnet subnet list \
  -g <network-rg> --vnet-name <vnet> \
  -o table

# NSG rules contain the minimums from section 3:
az network nsg rule list -g <network-rg> --nsg-name <nsg-master> -o table
az network nsg rule list -g <network-rg> --nsg-name <nsg-worker> -o table

# Route table default route points to the firewall private IP:
az network route-table route list -g <network-rg> --route-table-name <rt> -o table

# Peering both directions Connected:
az network vnet peering list -g <network-rg> --vnet-name <vnet> -o table
```

You can also run the installer-side preflight checks once tfvars are
in place:

```bash
make preflight
```

See [`preflight-checklist.md`](./preflight-checklist.md).

---

## 8. Hand-off to the cluster installer

Once the resources exist, give the cluster install team:

- The full Resource IDs of the five subnets
- The full Resource ID of the route table
- VNet name + RG (for the data-lookup)
- Workload RG name (where cluster VMs will land — can be the same as
  network RG or separate)
- Parent DNS zone name + RG + the subscription that holds it
- The identity to use for install (Service Principal or signed-in user)
  with the role assignments described in
  [`azure-identity-options.md`](./azure-identity-options.md)

Their `terraform/01-network/terraform.tfvars` will then look like:

```hcl
manage_network_resources = false
subnet_master_id    = "/subscriptions/.../snet-ocp-master"
subnet_worker_id    = "/subscriptions/.../snet-ocp-worker"
subnet_bootstrap_id = "/subscriptions/.../snet-ocp-bootstrap"
subnet_multus_id    = "/subscriptions/.../snet-ocp-multus"
subnet_sriov_id     = "/subscriptions/.../snet-ocp-sriov"
route_table_id      = "/subscriptions/.../routeTables/rt-ocp-egress"
```
