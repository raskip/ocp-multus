# Accessing the cluster

This repo deploys an internal OpenShift topology by default (`publish: Internal`). The cluster API, console, and application routes are reachable only from networks that can route to the Azure VNet and resolve the cluster private DNS zone.

## Endpoints

| Endpoint | Used by | Notes |
|---|---|---|
| `https://api.<cluster>.<base_domain>:6443` | `oc`, `kubectl`, kubeconfig, installer waits | Resolves to the internal API load balancer. |
| `https://console-openshift-console.apps.<cluster>.<base_domain>` | Browser access to the OpenShift web console | Resolves through the internal `*.apps` ingress load balancer. |

The installer creates a private DNS zone named `<cluster>.<base_domain>` by default and adds private records for `api`, `api-int`, and `*.apps`. Your workstation, jump host, or Bastion target must use DNS that can resolve that private zone.

## Access paths

### Private workstation path

Use this when your workstation is on a network peered to the hub through VPN, ExpressRoute, or vWAN. The path must be able to:

- route to the cluster spoke VNet,
- resolve the `<cluster>.<base_domain>` private DNS zone, and
- reach the API endpoint on TCP 6443 and the apps ingress on TCP 443.

For hub-spoke requirements, see [`network-prereqs.md` section 6](./network-prereqs.md#6-vnet-peering). For choosing between access patterns, see [`jump-host-access-decision.md`](./jump-host-access-decision.md).

### Optional Windows jump host

The repo can create a Windows browser/RDP jump host for console access, but only when you explicitly set `CREATE_WINDOWS_JUMP=true`. The default is `false`; the host is not required for `make all` and many enterprise tenants block Windows images or unused jump VMs.

Use this option only when you need an in-VNet browser for the internal console. Keep using your normal installer host or Linux jump host for `terraform`, `openshift-install`, and `oc` unless your operating model says otherwise.

### Azure Bastion

Azure Bastion avoids a public IP on the jump VM and can be a clean
enterprise option, but it is **not deployed by `make all`**. The
Standard SKU example in this repo is
[`examples/jump-host-access/C-azure-bastion/`](../examples/jump-host-access/C-azure-bastion/).
That example is opt-in and creates no Bastion resources unless you pass
`create_bastion=true`.

Azure Bastion Developer SKU can also be an option for portal-based RDP/SSH in supported scenarios without deploying a dedicated `AzureBastionSubnet` or Bastion public IP. Validate SKU availability, limits, and tenant policy before relying on it.

## How pods are reached

- Normal pod-to-pod and service traffic uses OpenShift networking and Kubernetes `ClusterIP` Services.
- HTTP/S application traffic uses OpenShift Routes through the internal `*.apps` ingress load balancer.
- Multus validation pods can also receive secondary-interface IPs from the Multus or host-device / SR-IOV-style subnets.

For the packet-path differences, see [`architecture.md` → Data-path contrast](./architecture.md#data-path-contrast-default-cni-vs-macvlan-vs-host-device).

## Credentials and kubeconfig

Azure install credentials are described in [`azure-credentials.md`](./azure-credentials.md). After installation, use the generated kubeconfig and kubeadmin credentials from the installer output location on the installer host. If your workflow persists these under a local secrets directory, follow the same document for credential handling and cleanup.
