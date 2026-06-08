# Multus macvlan validation

Use this after the cluster is installed and the workers are `Ready`.

## PodSecurity on OpenShift 4.14+

The macvlan and host-device CNI plugins need to manipulate host NICs
inside the pod network namespace, which requires the
`privileged` Pod Security Standard. On OpenShift 4.14+ the default
admission profile is `restricted`, so we set the `multus-demo`
namespace's enforce/audit/warn labels to `privileged` in
[`00-namespace.yaml`](./00-namespace.yaml). We also need to grant the
default service account access to the `privileged` SCC.

> The legacy versions of this demo created the namespace inline in
> `01-macvlan-nad.yaml` without the PodSecurity labels — that breaks on
> 4.14+ with `admission webhook \"pod-security.kubernetes.io...\" denied`.
> The namespace is now a separate manifest applied first.

## Steps

1. Apply the namespace (must be first — has PodSecurity labels):

   ```bash
   oc apply -f 00-namespace.yaml
   ```

2. Allow the namespace's default service account to use the `privileged`
   SCC (required for macvlan / host-device on OpenShift):

   ```bash
   oc adm policy add-scc-to-user privileged -z default -n multus-demo
   ```

3. Confirm the secondary NIC name inside RHCOS:

   ```bash
   oc get nodes -l node-role.kubernetes.io/worker -o name \
     | xargs -I{} oc debug {} -- chroot /host ip -br a
   ```

4. If the secondary NIC is not `eth1`, edit the `master` field in
   `01-macvlan-nad.yaml`. On arm64 (Ampere Altra) it's usually
   `enP*s1` — see [`docs/arm64-gotchas.md`](../../docs/arm64-gotchas.md).

5. Confirm the Whereabouts IPAM range in `01-macvlan-nad.yaml` is
   inside your Multus subnet and does not overlap Azure-assigned NIC IPs.

6. Apply the NAD and the demo pod:

   ```bash
   oc apply -f 01-macvlan-nad.yaml
   oc apply -f 02-dualnic-pod.yaml
   oc -n multus-demo rollout status deploy/dualnic --timeout=5m
   oc -n multus-demo get pods -o wide
   oc -n multus-demo exec deploy/dualnic -- ip -br a
   ```

The default example uses the upper `/24` of the Multus `/23` subnet
(`10.20.3.1`–`10.20.3.254`, IPAM range `10.20.2.0/23`) for pod secondary
addresses and reserves the lower `/24` (`10.20.2.0/24`) for
Azure-assigned NIC IPs.

## Cleanup

```bash
oc delete -f 02-dualnic-pod.yaml
oc delete -f 01-macvlan-nad.yaml
oc delete -f 00-namespace.yaml
```

## Why the explicit SCC + PodSecurity steps

The macvlan / host-device CNI plugins run inside the pod's network
namespace and must have `NET_ADMIN` + `NET_RAW` capabilities. Combined
with the secondary-NIC attachment, this requires the privileged SCC and
the privileged PodSecurity profile on the namespace. This is the same
pattern used in [`manifests/sriov/`](../sriov/) and is documented for
all Multus secondary-network demos.

