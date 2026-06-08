# `scripts/cluster-startup.sh`

Bring a gracefully shut down cluster back up: start VMs, approve kubelet
CSRs, uncordon, and wait until everything is healthy. See
[`operations.md`](../operations.md) for the full operating model.

## Synopsis

```text
scripts/cluster-startup.sh [--no-approve] [--skip-uncordon]
                           [--timeout <minutes>] [--dry-run]
```

## What it does

1. `az vm start` on the control plane VMs first.
2. Wait for the Kubernetes API to respond.
3. One pass of kubelet CSR approval (unless `--no-approve`), then a
   recurring approval loop during the wait below.
4. Wait until every master is `Ready`.
5. `az vm start` on the worker VMs (and the SR-IOV worker when
   present / `ENABLE_SRIOV=true`), now that the control plane is healthy.
6. Wait until every worker is `Ready`, approving CSRs as they appear.
7. Uncordon every node unless `--skip-uncordon`.
8. Wait for every `clusteroperator` to be `Available=True / Progressing=False / Degraded=False`.
9. `etcdctl endpoint health --cluster` as a final sanity check.

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--no-approve` | off | Don't auto-approve any CSR. You must run `oc adm certificate approve <csr>` yourself. |
| `--skip-uncordon` | off | Leave nodes cordoned (useful for inspection before workloads start). |
| `--timeout <minutes>` | `OPERATIONS_TIMEOUT_MIN` | Per-phase wait timeout (API, masters Ready, workers Ready, clusteroperators). |
| `--dry-run` | off | Print what would happen. No changes. |
| `-h`, `--help` | — | Show the usage block from the script header. |

## CSR auto-approval caveat

The auto-approver only acts on:

- `kubernetes.io/kube-apiserver-client-kubelet` from `system:node:*` or `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`.
- `kubernetes.io/kubelet-serving` from `system:node:*`.

It does **not** validate SANs, CN, or key usages. If your cluster is
exposed to untrusted CSRs or you want manual review, pass `--no-approve`.

## Environment variables

Same set as [`cluster-shutdown.sh`](./cluster-shutdown.md#environment-variables).

## Examples

```bash
# Default: start, auto-approve kubelet CSRs, uncordon, wait healthy
bash scripts/cluster-startup.sh

# Inspect before workloads come back
bash scripts/cluster-startup.sh --skip-uncordon

# Long-running install: bump the wait window
bash scripts/cluster-startup.sh --timeout 90

# Manual CSR review
bash scripts/cluster-startup.sh --no-approve
# ...in another terminal: oc get csr ; oc adm certificate approve <name>

# Inspect plan only
bash scripts/cluster-startup.sh --dry-run
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All nodes Ready, all clusteroperators converged (`Available=True / Progressing=False / Degraded=False`), and etcd reports all members healthy. A successful exit is a real "cluster is back" signal — safe to consume in unattended automation. |
| 1 | A wait phase timed out (API never came up, nodes didn't reach Ready, clusteroperators did not converge within `OPERATIONS_TIMEOUT_MIN`, or etcd health check failed). Re-run `make cluster-status` to see the current state. |
| 2 | Unknown flag / bad invocation. |

## Related

- [`cluster-shutdown.sh`](./cluster-shutdown.md)
- [`cluster-status.sh`](./cluster-status.md)
- [`operations.md`](../operations.md)
- [`scheduling.md`](../scheduling.md)
