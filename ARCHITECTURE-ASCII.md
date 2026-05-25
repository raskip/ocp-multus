# Architecture (ASCII)

Plain-text companion to [`ARCHITECTURE.md`](./ARCHITECTURE.md).

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
