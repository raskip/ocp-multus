# `scripts/cluster-status.sh`

Read-only health snapshot of the cluster and its underlying Azure VMs.
Safe to run at any time; never modifies anything.

## Synopsis

```text
scripts/cluster-status.sh
```

## What it prints

| Section | Source |
|---|---|
| Azure VM inventory and power state | `az vm list` filtered by VM name pattern |
| `oc` context (user + server) | `oc whoami` / `oc whoami --show-server` |
| Nodes (wide view) | `oc get nodes -o wide` |
| Cluster operators | `oc get co` |
| etcd member health | `oc -n openshift-etcd rsh -c etcdctl ... etcdctl endpoint health --cluster` |
| kube-apiserver-to-kubelet signer expiry | Annotation on the `kube-apiserver-to-kubelet-signer` secret |

The Azure section is skipped silently if `az` is not logged in (so the
script is still useful from a workstation that only has cluster
access).

## Flags

| Flag | Notes |
|---|---|
| `-h`, `--help` | Show the usage block from the script header. |

There are no other flags. The script is intentionally a snapshot, not a
configurable tool.

## Environment variables

Same as [`cluster-shutdown.sh`](./cluster-shutdown.md#environment-variables).
At minimum `CLUSTER_NAME` and `WORKLOAD_RESOURCE_GROUP` must resolve so
the VM lookup matches your cluster.

## Examples

```bash
# Routine health check
make cluster-status

# Before a planned shutdown, verify all green
make cluster-status

# After a restart, sanity check
make cluster-status
```

## When to run it

- Before a planned shutdown — confirm the cluster is healthy enough to
  trust.
- After a restart — confirm everything came back.
- During troubleshooting — one command, one summary.
- Before checking the cert expiry deadline — the script prints it.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Snapshot completed (note: individual sections may report unhealthy without raising the exit code; this is intentional so you always see all sections). |
| 1 | Could not load `config/cluster.env`. |

## Related

- [`cluster-shutdown.sh`](./cluster-shutdown.md)
- [`cluster-startup.sh`](./cluster-startup.md)
- [`cluster-scale-workers.sh`](./cluster-scale-workers.md)
- [`operations.md`](../operations.md)
