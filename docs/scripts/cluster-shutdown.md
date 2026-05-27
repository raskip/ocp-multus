# `scripts/cluster-shutdown.sh`

Gracefully shut down a self-managed OpenShift cluster on Azure VMs and
`az vm deallocate` the cluster compute. See
[`operations.md`](../operations.md) for the full operating model.

## Synopsis

```text
scripts/cluster-shutdown.sh [--graceful|--fast]
                            [--no-backup] [--yes] [--no-preflight]
                            [--timeout <minutes>]
                            [--shutdown-delay-min <minutes>]
                            [--drain-timeout <duration>]
                            [--force-deallocate-after-timeout]
                            [--dry-run]
```

## What it does

Default (`--graceful`):

1. Preflight (>= 3 control plane nodes; warn on NotReady masters). Skip with `--no-preflight`.
2. etcd backup unless `--no-backup`.
3. Confirm unless `--yes` (or `ASSUME_YES=1`).
4. Cordon every node.
5. Drain workers with `oc adm drain --delete-emptydir-data --ignore-daemonsets --force --timeout=<--drain-timeout>` (default `15s`).
6. `oc debug node/<n> -- chroot /host shutdown -h <--shutdown-delay-min>` on every node (workers first, then masters; deterministic last master).
7. Poll Azure until all cluster VMs are `stopped` / `deallocated`, up to `--timeout` minutes (default `OPERATIONS_TIMEOUT_MIN`, default 30).
8. **Refuse to deallocate** if step 7 timed out — unless `--force-deallocate-after-timeout`.
9. `az vm deallocate --no-wait` on every cluster VM (masters + workers + SR-IOV worker; bootstrap excluded).

`--fast` skips 1, 4–7. It confirms first, optionally backs up etcd, then goes
straight to `az vm deallocate`. Suitable for an idle cluster where you accept
the etcd risk.

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--graceful` / `--fast` | `--graceful` | `--fast` may corrupt etcd under load. |
| `--no-backup` | off | Skip the etcd backup. Don't use on a schedule. |
| `--yes`, `-y` | off | Skip the interactive confirm. Same as `ASSUME_YES=1`. |
| `--no-preflight` | off | Skip the >=3-masters / NotReady-masters checks. |
| `--timeout <minutes>` | `OPERATIONS_TIMEOUT_MIN` | Max minutes to wait for VMs to reach stopped/deallocated. |
| `--shutdown-delay-min <minutes>` | `1` | Argument to `shutdown -h` inside each node. |
| `--drain-timeout <duration>` | `15s` | Go duration passed to `oc adm drain --timeout`. |
| `--force-deallocate-after-timeout` | off | Deallocate even if in-OS shutdown didn't complete. **Accepts etcd risk.** |
| `--dry-run` | off | Print what would happen. No changes. |
| `-h`, `--help` | — | Show the usage block from the script header. |

## Environment variables

Loaded from `config/cluster.env`:

- `CLUSTER_NAME` — used to match VM names.
- `WORKLOAD_RESOURCE_GROUP` — resource group scanned for cluster VMs.
- `CLUSTER_SUBSCRIPTION_ID` — optional `az account set` target.
- `CONTROL_PLANE_VM_PREFIX`, `WORKER_VM_PREFIX`, `SRIOV_WORKER_VM_NAME` — VM naming pattern (defaults match Terraform).
- `BACKUP_DIR` — where etcd backup tarballs land (default `backups`).
- `OPERATIONS_TIMEOUT_MIN` — default wait timeout (default 30).
- `ASSUME_YES` — set to `1` to skip the confirm prompt non-interactively.

## Examples

```bash
# Default: graceful shutdown with backup, prompt for confirmation
bash scripts/cluster-shutdown.sh

# Same, no prompt — typical scheduled invocation
ASSUME_YES=1 bash scripts/cluster-shutdown.sh

# Long drain for stateful workloads, longer wait window
bash scripts/cluster-shutdown.sh --drain-timeout 5m --timeout 60

# Idle lab cluster, fast (etcd risk accepted)
bash scripts/cluster-shutdown.sh --fast --yes

# Inspect without changing anything
bash scripts/cluster-shutdown.sh --dry-run --yes
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All targeted VMs deallocate command issued successfully. |
| 1 | Preflight failed, in-OS shutdown timed out and `--force-deallocate-after-timeout` not set, or another fatal error. |
| 2 | Unknown flag / bad invocation. |

## Related

- [`cluster-startup.sh`](./cluster-startup.md)
- [`cluster-etcd-backup.sh`](./cluster-etcd-backup.md)
- [`cluster-scale-workers.sh`](./cluster-scale-workers.md)
- [`cluster-status.sh`](./cluster-status.md)
- [`operations.md`](../operations.md)
- [`scheduling.md`](../scheduling.md)
