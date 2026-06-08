# CNF node tuning (SCTP / THP / sysctls)

> **Status: template, blocked on vendor values.** These manifests are valid and
> apply, but the exact kernel parameters, sysctl lists, and THP policy are
> **placeholders** marked `TODO(vendor)`. Do not roll them to production nodes
> until the values are confirmed — each one triggers a **rolling reboot** of the
> CNF worker pool.

All tuning here targets the **`appworker`** MachineConfigPool defined in
[`../cnf-platform/00-machineconfigpool-appworker.yaml`](../cnf-platform/00-machineconfigpool-appworker.yaml),
so the base demo workers and control plane are never touched.

| File | What it does | Reboot |
|------|--------------|--------|
| `99-appworker-load-sctp.yaml` | Loads the `sctp` kernel module (signalling transport for AUSF/UDM, HSS/HLR). | yes |
| `99-appworker-thp.yaml` | Sets `transparent_hugepage=` kernel arg. | yes |
| `cni-sysctl-allowlist.yaml` | Allowlists interface-scoped sysctls Multus may set on secondary NICs. **Merge, don't replace** the cluster default. | no |
| `kubeletconfig-appworker.yaml` | Permits specific **unsafe** sysctls on the CNF pool only. | yes |

## Apply order (after the appworker pool exists)

```bash
# 1. Create the pool + label the nodes first (see ../cnf-platform/).
# 2. Inspect the existing allowlist before editing it:
oc -n openshift-multus get cm cni-sysctl-allowlist -o yaml

# 3. Apply tuning (pool reboots roll one node at a time):
oc apply -f 99-appworker-load-sctp.yaml
oc apply -f 99-appworker-thp.yaml
oc apply -f kubeletconfig-appworker.yaml
oc apply -f cni-sysctl-allowlist.yaml   # merged content only

# 4. Watch the rollout:
oc get mcp appworker -w
```

## TODO(vendor)

- Exact kernel parameters (THP policy, any isolcpus/hugepages via a
  `PerformanceProfile`/`Tuned` if required).
- Exact CNI sysctl allowlist entries (merge with cluster defaults).
- Exact `allowedUnsafeSysctls` list.
- Whether CPU pinning / hugepages (a `PerformanceProfile`) is needed.
