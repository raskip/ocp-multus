# Day-2 cluster operations

This runbook covers stopping, starting, and pausing a self-managed OpenShift
cluster deployed by this repository, so it can be paused to save Azure compute
cost without destroying it.

> **TL;DR**
>
> ```bash
> make etcd-backup        # always do this first
> make cluster-shutdown   # graceful drain + in-OS shutdown + Azure deallocate
> # ...later...
> make cluster-startup    # az vm start + CSR approval + uncordon + wait healthy
> ```

Why not just `az vm deallocate`? Because OpenShift's control plane runs etcd,
a distributed consensus store. Yanking power away from etcd VMs without first
quiescing the workload risks data corruption and a cluster that does not come
back up. Red Hat documents the exact sequence we automate here:

- [Shutting down the cluster gracefully (OpenShift 4.18)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/graceful-shutdown-cluster)
- [Restarting the cluster gracefully (OpenShift 4.18)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/graceful-restart-cluster)
- [Backing up etcd data](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore)

## When to use which option

| Goal | Use |
|---|---|
| Stop compute billing entirely (overnight, weekend, vacation) | `cluster-shutdown` |
| Pause workloads but keep API + etcd reachable | `workers-down` |
| Bring back a fully shut-down cluster | `cluster-startup` |
| Bring workers back, leave masters as-is | `workers-up` |
| Snapshot etcd for safety | `etcd-backup` |
| Verify cluster + Azure state | `cluster-status` |

`cluster-shutdown` saves the most compute cost. `workers-down` is useful when
you still want to log in and inspect the cluster but don't need workloads
running.

## Cost model

- `az vm stop` keeps compute reserved and **still bills compute** — never use it for cost savings.
- `az vm deallocate` releases compute (no compute cost) and keeps OS disks and NICs.
  - Standard managed disks: storage cost continues.
  - Static private IPs and Standard SKU load balancers / public IPs are preserved across deallocate.
- All scripts here use `deallocate`, not `stop`.

## Prerequisites

- `oc`, `az`, `jq`, `bash`, `make` on PATH.
- A valid `~/.kube/config` (or `KUBECONFIG`) pointing at the target cluster.
- `az login` to an account with `Virtual Machine Contributor` on the workload resource group.
- `config/cluster.env` populated (copy from `config/cluster.example.env`). Relevant fields for lifecycle:
  - `CLUSTER_NAME`, `WORKLOAD_RESOURCE_GROUP`
  - `CLUSTER_SUBSCRIPTION_ID` (optional; uses current `az` context otherwise)
  - `CONTROL_PLANE_VM_PREFIX`, `WORKER_VM_PREFIX`, `SRIOV_WORKER_VM_NAME`, `BOOTSTRAP_VM_NAME` (defaults match Terraform)
  - `BACKUP_DIR`, `OPERATIONS_TIMEOUT_MIN`

The scripts auto-discover cluster VMs by name pattern within the workload
resource group — they will never touch resources that don't match.

## Reference: certificate expiry

You can leave the cluster shut down for up to ~1 year. After that the
`kube-apiserver-to-kubelet-signer` certificate expires and you must manually
recover kubelet certificates on restart.

```bash
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer \
  -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
```

`make cluster-status` prints this value at the end of its output.

## Graceful shutdown

```bash
make etcd-backup
make cluster-shutdown                # or: bash scripts/cluster-shutdown.sh
```

What it does:

1. Prints the cert expiry deadline.
2. Takes an etcd backup to `backups/<UTC-timestamp>-<CLUSTER_NAME>/` (unless `--no-backup`).
3. Asks you to confirm (unless `--yes`).
4. Cordons every node.
5. Drains worker nodes (`--delete-emptydir-data --ignore-daemonsets --force --timeout=15s`).
6. Identifies the control plane node currently serving the API VIP via the `kubernetes` endpoints object.
7. Issues `oc debug node/<n> -- chroot /host shutdown -h 1` on every node, with the API VIP master last (otherwise the command itself fails mid-loop).
8. Waits until Azure reports every cluster VM as `PowerState/stopped`.
9. Runs `az vm deallocate --no-wait` on every cluster VM (masters + workers + SR-IOV worker). The bootstrap VM is never touched — it only exists during install.

Useful flags:

| Flag | Purpose |
|---|---|
| `--no-backup` | Skip the etcd backup. Only use if you took one separately. |
| `--yes` | Don't prompt for confirmation (for automation). |
| `--timeout <min>` | Override `OPERATIONS_TIMEOUT_MIN`. |
| `--dry-run` | Print what would happen without changing anything. |

## Fast shutdown (Azure deallocate only)

```bash
make cluster-shutdown-fast      # or: bash scripts/cluster-shutdown.sh --fast
```

This skips the in-OS graceful shutdown and goes straight to `az vm deallocate`.
**It can corrupt etcd** if the cluster is under load. Use only when:

- The cluster is idle.
- You have a fresh etcd backup.
- You accept the risk of a longer / failed restart.

The script prints a loud warning and still takes a backup by default. Pass
`--yes` to skip the confirmation prompt in automation.

## Restarting

```bash
make cluster-startup            # or: bash scripts/cluster-startup.sh
```

What it does:

1. `az vm start` the control plane VMs first.
2. `az vm start` the worker VMs (including the SR-IOV worker).
3. Waits for the Kubernetes API to respond.
4. Loop-approves pending kubelet CSRs while waiting for nodes (auto-approves only `kubernetes.io/kube-apiserver-client-kubelet` and `kubernetes.io/kubelet-serving` for `system:node:*` requesters; anything else is logged and left alone).
5. Waits until every control plane node reports Ready, then every worker.
6. Uncordons every node.
7. Waits until every clusteroperator is `Available=True / Progressing=False / Degraded=False`.

Useful flags:

| Flag | Purpose |
|---|---|
| `--no-approve` | Don't auto-approve CSRs; show them and continue. You'll need to `oc adm certificate approve <csr>` manually. |
| `--skip-uncordon` | Leave nodes cordoned (useful for inspection). |
| `--timeout <min>` | Override `OPERATIONS_TIMEOUT_MIN`. |
| `--dry-run` | Print what would happen without changing anything. |

If the cluster has been down a long time (close to or past the cert expiry
date), you may see many pending CSRs at startup. The auto-approver handles
kubelet ones automatically; for anything else consult [Red Hat docs on certificate recovery](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/recovering-from-expired-control-plane-certificates).

## Pausing workers only

When you want to keep `oc` access and etcd quorum but pause workload compute:

```bash
make workers-down       # cordon + drain workers, then deallocate worker VMs
# ...later...
make workers-up         # start workers, auto-approve CSRs, uncordon
```

Use `bash scripts/cluster-scale-workers.sh status` to see worker VM state and
node Ready/SchedulingDisabled together. Masters and the SR-IOV worker are
included in worker scaling because they all carry workloads in this demo.

## Status snapshot

```bash
make cluster-status
```

Prints:

- Azure VM inventory and power state.
- `oc` context (user + server).
- `oc get nodes -o wide`.
- `oc get co`.
- `etcdctl endpoint health --cluster`.
- Certificate expiry.

Read-only; safe to run at any time.

## Backups

`make etcd-backup` runs `/usr/local/bin/cluster-backup.sh` inside a Ready
control plane node via `oc debug`, tars the resulting directory, and copies
it back locally under `backups/<UTC-timestamp>-<CLUSTER_NAME>/` together with a
`metadata.json`. `.gitignore` excludes the contents of `backups/`, so backups
are never accidentally committed.

To restore from a backup (if a restart fails), follow Red Hat's
[restoring to a previous cluster state](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore)
procedure. This script is intentionally not in scope here — etcd restore is a
sensitive operation that should be done manually with full awareness of what's
about to happen to the cluster.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `cluster-shutdown` complains "no cluster VMs found" | VM names don't match the pattern in `config/cluster.env` | Set `CONTROL_PLANE_VM_PREFIX` / `WORKER_VM_PREFIX` / `SRIOV_WORKER_VM_NAME` to match what Terraform created. |
| `oc debug ... shutdown -h 1` returns non-zero | Node already going down, or container couldn't start because kubelet is stressed | Script logs a warning and continues — usually fine. |
| Nodes stuck `NotReady` after startup | Pending CSRs | The startup script auto-approves kubelet CSRs every loop. If something else is pending, run `oc get csr` and inspect. |
| `clusteroperators` won't converge | Workload PVs / storage provider not back yet, or you started workers before masters were healthy | Re-run `make cluster-status`, give it a few minutes, then `wait_for_cluster_operators` again via `bash scripts/cluster-startup.sh --skip-uncordon`. |
| Cluster has been down > 1 year | kube-apiserver-to-kubelet signer expired | Follow the [expired certificate recovery procedure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/recovering-from-expired-control-plane-certificates). |
| etcd looks unhealthy after restart | One control plane VM started late or was hard-stopped previously | Try `make cluster-status` after a few minutes. If still unhealthy, restore from the most recent etcd backup. |

## Out of scope

- Restoring etcd from backup (do this manually with Red Hat's documented procedure).
- Hibernation (this is UPI, not Azure Red Hat OpenShift / ARO — ARO has its own managed hibernation feature).
- Cross-region failover.
- Automated cost reporting.
