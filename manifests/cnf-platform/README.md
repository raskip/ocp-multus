# CNF platform: pool, roles, SCC, scheduling

> **Status: template, partly blocked on vendor values.** The pool, ServiceAccount
> and labelling are ready; the SCC capabilities and the PriorityClass value are
> `TODO(vendor)`.

This sets up the dedicated CNF worker pool that the node-tuning
([`../node-tuning/`](../node-tuning/)) and workload ([`../cnf/`](../cnf/))
manifests depend on.

Applied automatically by `make cnf-apply`; see [`docs/cnf-telco-profile.md`](../../docs/cnf-telco-profile.md). You can still apply manually as below.

| File | Purpose |
|------|---------|
| `00-machineconfigpool-appworker.yaml` | `appworker` MachineConfigPool; tuning MachineConfigs land only here. |
| `11-serviceaccount-cnf.yaml` | `cnf-sa` ServiceAccount in the `cnf` namespace. |
| `10-scc-cnf.yaml` | Scoped SCC (NET_ADMIN/NET_RAW only) bound to `cnf-sa` — least privilege instead of blanket `privileged`. |
| `20-priorityclass.yaml` | `cnf-high` PriorityClass for signalling workloads. |
| `../../scripts/label-cnf-nodes.sh` | Labels nodes `node-role.kubernetes.io/appworker` (+ `is_worker`/`is_edge`). |

## Apply order

```bash
# 1. Namespace (from ../cnf/) must exist first:
oc apply -f ../cnf/00-namespace.yaml

# 2. Platform objects:
oc apply -f 11-serviceaccount-cnf.yaml
oc apply -f 10-scc-cnf.yaml
oc apply -f 20-priorityclass.yaml
oc apply -f 00-machineconfigpool-appworker.yaml

# 3. Label the CNF workers (creates/*fills* the appworker pool):
../../scripts/label-cnf-nodes.sh vm-worker-0-<cluster> vm-worker-1-<cluster>
oc get mcp appworker -w

# 4. Now apply ../node-tuning/ and ../cnf/.
```

## TODO(vendor)

- SCC: real capability / host-network / host-port requirements (widen only as
  needed; the scoped SCC avoids blanket `privileged`).
- PriorityClass value + preemption policy (or use the CNFs' own classes).
- Node-label scheme if the CNFs expect specific topology labels beyond
  `is_worker` / `is_edge`.
