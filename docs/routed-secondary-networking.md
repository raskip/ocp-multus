# Routable secondary pod networking: Azure design decision

Status reviewed: **2026-09-01**

## Required behavior

The target workload keeps the normal OpenShift pod network on `eth0` and gets
an additional interface such as `net1`. The secondary address must work:

- between pods on different workers;
- from a pod to Azure and on-premises destinations; and
- from Azure/on-premises back to the pod without unintended SNAT.

This is different from replacing the pod's primary network.

## Current fit assessment

| Design | Keeps default `eth0` + adds `net1` | Cross-node/external routing | Current assessment |
|---|---:|---:|---|
| macvlan on an Azure secondary NIC | yes | no reliable Azure cross-node path | Do not use as the routed baseline. Azure does not recognize the synthetic child MAC. |
| host-device with a real Azure NIC/IP | yes | expected to use native Azure routing | Control case. One pod consumes one complete NIC, so density is limited. |
| routed ipvlan/Multus with per-node pod prefixes | yes | possible with explicit node/router routes | Preferred scalable spike, subject to Red Hat support and Azure/on-prem route ownership. |
| primary Layer3 CUDN with route advertisements | no; it changes the selected workload's primary network | documented BGP route advertisement path | Useful compatibility experiment, but it does not by itself satisfy the stated dual-interface requirement. |
| secondary UDN/CUDN | yes in supported UDN combinations | north-south behavior depends on topology/version and is not the documented no-overlay path | Do not assume it can advertise arbitrary secondary pod routes. Prove API and data-path support first. |

## Important feature boundary

OpenShift `RouteAdvertisements` selects the default pod network or
`ClusterUserDefinedNetwork` objects. It is not a generic BGP export mechanism
for addresses allocated by Multus NetworkAttachmentDefinitions such as
macvlan, ipvlan, host-device, or SR-IOV networks.

The OpenShift 4.22 no-overlay procedure is documented for a **primary Layer3
CUDN**, is **Technology Preview**, requires `TechPreviewNoUpgrade`, and lists
bare-metal infrastructure as a prerequisite. The present lab is OpenShift 4.18
on Azure UPI ARM64. The lab can be demolished and rebuilt for a compatibility
test, but a working Azure test must still be described as outside that
documented platform boundary unless Red Hat confirms support in writing.

Primary Red Hat references:

- [Route advertisements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/advanced_networking/route-advertisements)
- [Configuring primary networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/multiple_networks/primary-networks)
- [Understanding user-defined networks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/multiple_networks/understanding-user-defined-networks)

## Select the Azure BGP control plane

Azure Route Server can exchange BGP routes with VM-based routing appliances in
its VNet and, under the documented topology, in a directly peered VNet. It
does not attach directly to pod interfaces. The BGP peer must be a node or
dedicated router that can forward traffic to the advertised pod prefix.

However, Azure Route Server cannot be deployed in a spoke VNet that is
connected to an Azure Virtual WAN hub. In that topology, evaluate **BGP peering
with the Virtual WAN hub router** instead. A BGP endpoint in a VNet directly
connected to the virtual hub can peer with the hub and exchange routes with
VPN/ExpressRoute connections when the hub routing configuration allows it.

Selection rule:

- **Traditional hub-and-spoke VNet:** consider Azure Route Server in the
  approved hub or spoke topology.
- **Azure Virtual WAN-connected spoke:** do not add Route Server to the spoke;
  request Virtual WAN hub BGP peering for the approved node/router endpoints.

Before selecting either control plane:

1. Determine whether the spoke uses traditional VNet peering or an Azure
   Virtual WAN VNet connection.
2. Confirm the customer permits worker nodes to peer, or requires dedicated
   routing appliances.
3. Peer every accepted router with both Azure-side BGP addresses.
4. Permit BGP TCP/179 only between the approved endpoint and Azure-side peer
   addresses.
5. Confirm learned routes propagate through the hub and
   ExpressRoute/VPN to the required on-premises networks.
6. Confirm on-premises accepts the proposed pod prefixes and returns them
   through the same routing domain.
7. Keep pod prefixes outside all Azure VNet address spaces. Azure same-VNet
   system routes have higher precedence than a Route Server-learned BGP route,
   so advertising a more specific pod prefix carved from the VNet is not a
   sound design.

Primary Microsoft references:

- [Peer Route Server with an NVA in a different VNet](https://learn.microsoft.com/azure/route-server/peer-route-server-with-virtual-appliance-in-different-vnet)
- [Azure Route Server FAQ](https://learn.microsoft.com/azure/route-server/route-server-faq)
- [Route Server routing preference](https://learn.microsoft.com/azure/route-server/hub-routing-preference)
- [BGP peering with an Azure Virtual WAN virtual hub](https://learn.microsoft.com/azure/virtual-wan/scenario-bgp-peering-hub)
- [Configure Virtual WAN hub BGP peering](https://learn.microsoft.com/azure/virtual-wan/create-bgp-peering-hub-powershell)

Virtual WAN-specific constraints to confirm with the central network team:

- the BGP endpoint must be in a VNet directly connected to the virtual hub;
- the peer ASN must be a permitted 16-bit ASN and differ from the hub ASN;
- both hub-router peer addresses must be configured consistently;
- the hub supports at most eight BGP peers;
- branch-to-branch routing must be enabled for exchange with VPN and
  ExpressRoute branches;
- a secured virtual hub requires routing intent for this peering scenario;
- prefixes contained inside the connected VNet address space are not propagated
  onward to on-premises, reinforcing the requirement for a separate,
  non-overlapping secondary pod prefix.

## Recommended implementation order

1. Run the read-only discovery:

   ```bash
   make routing-discovery
   # Keep a local artifact if required:
   make routing-discovery \
     ROUTING_DISCOVERY_FLAGS="--out /tmp/ocp-routing-discovery.txt"
   ```

2. Obtain approval for:

   - a non-overlapping secondary pod prefix;
   - Route Server, Virtual WAN hub BGP, or dedicated-router ownership;
   - ExpressRoute/VPN propagation and on-premises return routes;
   - Red Hat support for the selected Multus/BGP combination.

3. Validate `manifests/hostdevice-xnode/` as the real-NIC/IP control path.
4. Rebuild the disposable lab on the selected OpenShift release and feature
   set.
5. Test a routed Multus secondary network that preserves `eth0 + net1`.
6. Separately test CUDN route advertisements and record whether the resulting
   interface model matches the requirement.

Do not integrate BGP resources into the normal install path until both the
control case and the on-premises return path work.

## Acceptance criteria

For pods on two different workers:

- `eth0` retains normal pod, Service, DNS, API, and ingress behavior;
- `net1` has the approved secondary address and route table;
- both secondary addresses communicate cross-node;
- both initiate traffic to Azure and on-premises test endpoints through
  `net1`;
- Azure and on-premises endpoints initiate traffic back to both addresses;
- packet captures show the pod secondary source address, expected next hop,
  and no unintended SNAT;
- node drain and failure withdraw or move the affected route without duplicate
  addresses or stale next hops.

## Repository safety rules

- All new routing/BGP behavior must be opt-in.
- BYO-network remains the default enterprise ownership model.
- Route Server, Virtual WAN, ExpressRoute, VPN, hub firewall, and on-premises
  route changes are never taken over implicitly.
- Customer resource IDs, addresses, domains, names, and discovery output are
  not committed.
- Technology Preview or unsupported paths must be clearly labeled and must not
  be enabled accidentally.
