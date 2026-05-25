# `scripts/cluster-scale-workers.sh`

Stop or start ONLY the worker VMs (including the SR-IOV worker),
leaving the control plane up. Cheaper than a full cluster shutdown when
you only want to pause workload compute and still need `oc` access.

## Synopsis

```text
scripts/cluster-scale-workers.sh down   [--yes] [--timeout <min>] [--dry-run]
scripts/cluster-scale-workers.sh up     [--no-approve] [--skip-uncordon]
                                        [--timeout <min>] [--dry-run]
scripts/cluster-scale-workers.sh status
```

## Subcommands

### `down`

1. Confirm unless `--yes` / `ASSUME_YES=1`.
2. Cordon every worker node.
3. Drain every worker node.
4. `oc debug node/<n> -- chroot /host shutdown -h 1` on every worker.
5. Wait until Azure reports every worker as `stopped` or `deallocated`,
   up to `--timeout` minutes.
6. **Refuse to deallocate** if step 5 timed out — investigate the stuck
   workers and re-run.
7. `az vm deallocate --no-wait` on every worker VM.

The control plane stays up; etcd quorum is unaffected.

### `up`

1. `az vm start` on every worker VM.
2. Wait for every worker to report `Ready`, auto-approving kubelet CSRs
   unless `--no-approve`.
3. Uncordon every worker unless `--skip-uncordon`.

### `status`

Read-only: prints the Azure power state of every worker VM alongside
the cluster's node Ready / SchedulingDisabled state. Safe to run any
time.

## Flags

| Flag | Subcommand | Notes |
|---|---|---|
| `--yes`, `-y` | `down` | Skip the interactive confirm. Same as `ASSUME_YES=1`. |
| `--no-approve` | `up` | Don't auto-approve CSRs. |
| `--skip-uncordon` | `up` | Leave workers cordoned after start. |
| `--timeout <min>` | `down`, `up` | Override `OPERATIONS_TIMEOUT_MIN`. |
| `--dry-run` | `down`, `up` | Print what would happen. No changes. |
| `-h`, `--help` | any | Show the usage block. |

## Environment variables

Same as [`cluster-shutdown.sh`](./cluster-shutdown.md#environment-variables).

## Examples

```bash
# Pause workloads for the night, keep API + etcd up
ASSUME_YES=1 bash scripts/cluster-scale-workers.sh down --timeout 30

# In the morning
bash scripts/cluster-scale-workers.sh up

# Check current state at a glance
bash scripts/cluster-scale-workers.sh status

# Dry-run a planned scale-down
bash scripts/cluster-scale-workers.sh down --dry-run --yes
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Subcommand completed successfully. |
| 1 | Drain failed catastrophically, workers didn't gracefully stop in time, or workers didn't come back Ready. |
| 2 | Unknown subcommand / unknown flag. |

## Related

- [`cluster-shutdown.sh`](./cluster-shutdown.md) — full cluster including masters.
- [`cluster-startup.sh`](./cluster-startup.md)
- [`cluster-status.sh`](./cluster-status.md)
- [`OPERATIONS.md`](../../OPERATIONS.md)
