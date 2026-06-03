# arm64 (Ampere Altra) gotchas on Azure

This repo supports both `x86_64` (Intel Ice Lake D*s_v5) and `arm64`
(Ampere Altra D*ps_v5) cluster VMs via the `ARCHITECTURE` setting in
`config/cluster.env`. The Terraform stages, RHCOS download, and
`openshift-install` flow all branch on that single variable.

This page collects the small but real differences that have caused
confusion when deploying an arm64 cluster on Azure UPI.

## 1. Secondary NIC name is not `eth1`

On Ampere Altra VMs, RHCOS typically names interfaces with the
`enP*s*`/`enP*p*` *predictable network interface* convention rather than
the `ethN` legacy convention.

A worker with two NICs on `Standard_D4ps_v5` often looks like this:

```
$ oc debug node/<worker> -- chroot /host ip -br a
lo               UNKNOWN        127.0.0.1/8 ::1/128
enP24214s1       UP             10.0.1.10/24       # primary
enP24215s1       UP             10.0.2.10/24       # secondary (Multus)
ovs-system       DOWN
br-int           UNKNOWN        ...
```

The macvlan demo manifest assumes `eth1` for the parent interface. On
arm64, edit `manifests/multus/01-macvlan-nad.yaml`:

```yaml
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "enP24215s1",     # was "eth1"
      ...
    }
```

**Pre-flight check before applying the demo:**

```bash
oc get nodes -l node-role.kubernetes.io/worker -o name \
  | xargs -I{} oc debug {} -- chroot /host ip -br a 2>&1 \
  | grep -E '^en|^eth'
```

Confirm the parent NIC name and the IP range it sits on, then update
the NAD before `oc apply`.

## 2. Host-device validation worker

The same naming applies to the optional dedicated/host-device worker
(`manifests/sriov/01-hostdevice-nad.yaml`). On arm64 the third NIC is
typically `enP*s2` or `enP*p2`. Verify with `ip -br a` inside the host
namespace and update the manifest before applying.

## 3. VM SKU sizing

| Role          | x86_64 default       | arm64 equivalent      |
|---------------|----------------------|-----------------------|
| Master        | `Standard_D8s_v5`    | `Standard_D8ps_v5`    |
| Worker        | `Standard_D4s_v5`    | `Standard_D4ps_v5`    |
| Multus extra NIC worker | same          | same (D*ps_v5)        |

D*ps_v5 supports Accelerated Networking (required for the host-device
demo) and has the same generation of NIC drivers as D*s_v5. Confirm
quota with:

```bash
az vm list-usage --location "$REGION" -o table \
  | grep -E 'Dpsv5|standardDPSv5Family'
```

## 4. RHCOS image tarball

`make image` downloads the RHCOS image matching `ARCHITECTURE`. The
default arm64 image is published under
`https://mirror.openshift.com/pub/openshift-v4/aarch64/dependencies/rhcos/<channel>/`
and the helper script picks it automatically. If you see a "no matching
image found" error, double-check that the `ARCHITECTURE` value in
`config/cluster.env` is exactly `arm64` (not `aarch64`).

## 5. `openshift-install` binary

If you run the installer from an arm64 host (e.g. Apple silicon, an
arm64 jump VM), `make tools` will fetch the matching `openshift-install`
and `oc` binaries automatically. You can mix and match — an x86_64 jump
VM can deploy an arm64 cluster and vice versa. See
[cpu-architecture.md](./cpu-architecture.md) → *Host CPU vs cluster
CPU*.

## 6. Mixed-architecture clusters

This repo does **not** currently support mixed-architecture worker pools
(some x86_64, some arm64 workers in the same cluster). All cluster VMs
share the `ARCHITECTURE` value. If you need mixed pools, you'd add a
separate worker stage with its own ignition config — out of scope for
the canonical install.

## 7. `oc debug node/<n>` works the same

There is no arm64-specific `oc debug` behaviour. `chroot /host` works
identically. Just remember that whatever you exec inside `chroot /host`
must be an arm64 binary (most coreutils are; downloaded helper binaries
may need an arm64 build).
