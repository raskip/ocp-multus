# Multus macvlan validation

Use this after the cluster is installed and the workers are `Ready`.

1. Confirm the secondary NIC name inside RHCOS:

   ```bash
   oc get nodes -l node-role.kubernetes.io/worker -o name \
     | xargs -I{} oc debug {} -- chroot /host ip -br a
   ```

2. If the secondary NIC is not `eth1`, edit the `master` field in `01-macvlan-nad.yaml`.

3. Confirm the Whereabouts IPAM range in `01-macvlan-nad.yaml` is inside your Multus subnet and does not overlap Azure-assigned NIC IPs.

4. Apply and test:

   ```bash
   oc apply -f 01-macvlan-nad.yaml
   oc apply -f 02-dualnic-pod.yaml
   oc -n multus-demo rollout status deploy/dualnic --timeout=5m
   oc -n multus-demo get pods -o wide
   oc -n multus-demo exec deploy/dualnic -- ip -br a
   ```

The default example uses `10.20.2.128/25` for pod secondary addresses and reserves the lower half of `10.20.2.0/24` for Azure-assigned NIC IPs.
