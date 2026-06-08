# Host-device / SR-IOV-style validation

This demo uses Multus host-device CNI to move a dedicated Azure Accelerated Networking NIC into a pod network namespace.

## Prerequisites

- Optional host-device worker is enabled with `ENABLE_SRIOV=true`, joined, and `Ready`; otherwise these validation manifests have no target node.
- Node is labeled:

  ```bash
  oc label node <worker-node-name> sriov.demo/capable=true
  ```

- Dedicated NIC name is confirmed inside RHCOS. The example assumes `eth2`.
- Static IP and gateway in `01-hostdevice-nad.yaml` match the Azure-assigned NIC IP and subnet gateway.

## Deploy

```bash
oc apply -f 00-namespace.yaml
oc adm policy add-scc-to-user privileged -z default -n sriov-demo
oc apply -f 01-hostdevice-nad.yaml
oc apply -f 02-demo-pod.yaml
oc -n sriov-demo wait --for=condition=Available deploy/sriov-demo --timeout=180s
oc -n sriov-demo logs deploy/sriov-demo
```

## Expected

- Pod has `eth0` on the default OVN network and `net1` from the host-device NIC.
- While the pod is alive, the host loses the dedicated NIC.
- Only one pod at a time can claim the host-device NIC.

## Cleanup

```bash
oc delete -f 02-demo-pod.yaml
```

If egress fails, verify NSG rules, route tables, IP forwarding, and the static IP in `01-hostdevice-nad.yaml`.
