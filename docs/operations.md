# Day-2 cluster operations

This runbook covers stopping, starting, and pausing a self-managed OpenShift
cluster deployed by this repository, so it can be paused to save Azure compute
cost without destroying it.

> **TL;DR**
>
> ```bash
> make etcd-backup        # always do this first (the scripts call this too, but it's a good habit)
> make cluster-shutdown   # graceful drain + in-OS shutdown + Azure deallocate
> # ...later...
> make cluster-startup    # az vm start + CSR approval + uncordon + wait healthy
> ```
>
> For scheduled / unattended use see [`scheduling.md`](./scheduling.md).
> For the full per-script command reference see [`docs/scripts/`](./scripts/).
> For CPU architecture choice (x86_64 vs arm64) see [`cpu-architecture.md`](./cpu-architecture.md).
> For saving kubeconfig, kubeadmin password, Terraform state, SP JSON, and
> optional Windows jump-host credentials see
> [`credential-backup.md`](./credential-backup.md).

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
| Save local install credentials/state | `save-credentials` |

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
- The cluster `oc` user must have `cluster-admin` (the scripts use `oc debug node/<name>`, `oc adm cordon/drain`, `oc adm certificate approve`, and `oc rsh` against `openshift-etcd`).
- `config/cluster.env` populated (copy from `config/cluster.example.env`). Relevant fields for lifecycle:
  - `CLUSTER_NAME`, `WORKLOAD_RESOURCE_GROUP`
  - `CLUSTER_SUBSCRIPTION_ID` (optional; uses current `az` context otherwise)
  - `CONTROL_PLANE_VM_PREFIX`, `WORKER_VM_PREFIX`, `SRIOV_WORKER_VM_NAME`, `BOOTSTRAP_VM_NAME` (defaults match Terraform)
  - `BACKUP_DIR`, `OPERATIONS_TIMEOUT_MIN`

The scripts auto-discover cluster VMs by exact name pattern within the
workload resource group — they will never touch resources that don't match.

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
make etcd-backup            # optional — cluster-shutdown also takes one by default
make cluster-shutdown       # or: bash scripts/cluster-shutdown.sh
```

What it does (full sequence):

1. **Preflight checks** — requires at least 3 control plane nodes and warns
   if any control plane node is NotReady. Skip with `--no-preflight` if you
   know what you're doing.
2. **etcd backup** to `backups/<UTC-timestamp>-<CLUSTER_NAME>/` (skip with `--no-backup`).
3. **Confirm** the destructive action (skip with `--yes` or `ASSUME_YES=1`).
4. **Cordon** every node so no new pods land mid-shutdown.
5. **Drain** worker nodes
   (`--delete-emptydir-data --ignore-daemonsets --force --timeout=<--drain-timeout>`; default `15s`).
6. **In-OS shutdown** via `oc debug node/<n> -- chroot /host shutdown -h <--shutdown-delay-min>`
   (default `1` minute). Workers first, then masters. A deterministic last
   control plane node is processed last so the shutdown loop has a stable
   termination target (on Azure UPI the API VIP lives on a Standard Load
   Balancer frontend, not pinned to any single master, so this ordering is a
   hint, not a strict invariant).
7. **Wait for Azure** to report every cluster VM as `PowerState/stopped` or
   `PowerState/deallocated`, up to `--timeout` minutes (default
   `OPERATIONS_TIMEOUT_MIN`, set in `config/cluster.env`, default 30).
8. **Refusal guard**: if step 7 times out, the script *refuses* to run
   `az vm deallocate` (because the underlying etcd quorum may be
   inconsistent). Pass `--force-deallocate-after-timeout` only if you
   accept the etcd corruption risk.
9. **`az vm deallocate --no-wait`** the cluster VMs in batch
   (masters + workers + SR-IOV worker). The bootstrap VM is never touched.

### Flags (cluster-shutdown.sh)

| Flag | Purpose |
|---|---|
| `--graceful` | Default. Full Red Hat procedure as above. |
| `--fast` | Skip preflight, drain, in-OS shutdown, and wait. Go straight to confirmation + optional backup + deallocate. **Can corrupt etcd** under load. |
| `--no-backup` | Skip the etcd backup. Only use if you took one separately. |
| `--yes`, `-y` | Don't prompt for confirmation. Same as `ASSUME_YES=1`. |
| `--no-preflight` | Skip the >=3-masters / NotReady-masters preflight checks. |
| `--timeout <minutes>` | Override `OPERATIONS_TIMEOUT_MIN`. Default 30. |
| `--shutdown-delay-min <minutes>` | Minutes to pass to `shutdown -h` inside each node. Default 1. |
| `--drain-timeout <duration>` | Per-node `oc adm drain` timeout (Go duration). Default `15s`. |
| `--force-deallocate-after-timeout` | If the in-OS shutdown didn't complete in time, deallocate anyway. **Accepts etcd corruption risk.** |
| `--dry-run` | Print what would happen without changing anything. |

See [`docs/scripts/cluster-shutdown.md`](./scripts/cluster-shutdown.md) for examples.

## Fast shutdown (Azure deallocate only)

```bash
make cluster-shutdown-fast      # or: bash scripts/cluster-shutdown.sh --fast
```

This skips the in-OS graceful shutdown and goes straight to `az vm deallocate`.
**It can corrupt etcd** if the cluster is under load. Use only when:

- The cluster is idle.
- You have a fresh etcd backup.
- You accept the risk of a longer / failed restart.

The script prompts for confirmation BEFORE doing anything destructive (and
before the backup, so you can bail out fast). It still takes a backup by
default unless you pass `--no-backup`. Pass `--yes` to skip the confirmation
in automation.

## Restarting

```bash
make cluster-startup            # or: bash scripts/cluster-startup.sh
```

What it does (full sequence):

1. **Start the control plane first** — `az vm start` on the master VMs only.
2. **Wait for the Kubernetes API** to respond (polls `oc get nodes`).
3. **Approve CSRs**: one quick pass, then a recurring approval loop during
   the wait below.
4. **Wait until every master node reports Ready.**
5. **Start the workers** — `az vm start` on the worker VMs and the SR-IOV
   worker, now that the control plane is healthy.
6. **Wait until every worker reports Ready** (auto-approves kubelet CSRs as they appear).
7. **Uncordon** every node (skip with `--skip-uncordon`).
8. **Wait for cluster operators** to converge: `Available=True / Progressing=False / Degraded=False` on every `clusteroperator`. If this does not happen within `OPERATIONS_TIMEOUT_MIN`, the script exits non-zero — startup is not considered successful.
9. **etcd health check** (`etcdctl endpoint health --cluster`) to confirm the cluster came back cleanly. A failure here also exits non-zero, so unattended automation (cron, GHA) treats it as a real failure.

### CSR auto-approval (important caveat)

The auto-approver only handles:

- `kubernetes.io/kube-apiserver-client-kubelet` requested by `system:node:*` or `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`
- `kubernetes.io/kubelet-serving` requested by `system:node:*`

It **does not** validate certificate SANs, CN, key usages, or any other field
beyond the signer + requester prefix. If the cluster is multi-tenant, exposed
to untrusted workloads that can create CSRs, or you simply want manual review,
pass `--no-approve` and approve CSRs explicitly with `oc adm certificate approve <csr>`.

### Flags (cluster-startup.sh)

| Flag | Purpose |
|---|---|
| `--no-approve` | Don't auto-approve CSRs. The script lists them and continues to wait — you must approve them manually. |
| `--skip-uncordon` | Leave nodes cordoned (useful for inspection before workloads come back). |
| `--timeout <minutes>` | Override `OPERATIONS_TIMEOUT_MIN`. Default 30. |
| `--dry-run` | Print what would happen without changing anything. |

If the cluster has been down a long time (close to or past the cert expiry
date), you may see many pending CSRs at startup. The auto-approver handles
kubelet ones automatically; for anything else consult [Red Hat docs on certificate recovery](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/recovering-from-expired-control-plane-certificates).

See [`docs/scripts/cluster-startup.md`](./scripts/cluster-startup.md) for examples.

## Pausing workers only

When you want to keep `oc` access and etcd quorum but pause workload compute:

```bash
make workers-down       # cordon + drain workers, in-OS shutdown, wait stopped, then deallocate
# ...later...
make workers-up         # start workers, auto-approve CSRs, wait Ready, uncordon
```

`workers-down` runs the same wait-for-stopped + refuse-to-deallocate safety
as the full graceful shutdown, so workers that don't gracefully stop will
not be hard-deallocated. The SR-IOV worker is included in the worker set.

Use `bash scripts/cluster-scale-workers.sh status` to see worker VM state
and node Ready/SchedulingDisabled together.

See [`docs/scripts/cluster-scale-workers.md`](./scripts/cluster-scale-workers.md).

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
- Certificate expiry (`kube-apiserver-to-kubelet-signer`).

Read-only; safe to run at any time. See [`docs/scripts/cluster-status.md`](./scripts/cluster-status.md).

## Backups

`make etcd-backup` runs `/usr/local/bin/cluster-backup.sh` inside a Ready
control plane node via `oc debug`, tars the resulting directory, and copies
it back locally under `backups/<UTC-timestamp>-<CLUSTER_NAME>/` together with a
`metadata.json`. The directory contains:

```
backups/20260525T080000Z-lab/
├── snapshot_2026-05-25_080013.db
├── static_kuberesources_2026-05-25_080013.tar.gz
└── metadata.json
```

`.gitignore` excludes the contents of `backups/`, so backups are never
accidentally committed.

To restore from a backup (if a restart fails), follow Red Hat's
[restoring to a previous cluster state](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore)
procedure. This script is intentionally not in scope here — etcd restore is a
sensitive operation that should be done manually with full awareness of what's
about to happen to the cluster.

See [`docs/scripts/cluster-etcd-backup.md`](./scripts/cluster-etcd-backup.md).

## End-to-end walkthrough

A typical paused-overnight cycle. Output is abbreviated for readability:
real runs interleave per-node `cordon`/`drain`/`shutdown` lines, repeated
"still waiting" lines, etcd member tables, and the final `oc get nodes`
/ `oc get co` dumps. The format is real, though — the scripts emit:

- `[<UTC-ts>] === step ===` for major step headers (with a blank line in
  front)
- `[<UTC-ts>] [INFO]  message` for detail lines (`[WARN]` / `[ERROR]`
  for warnings and errors)

Timestamps and node names will differ for your cluster.

### Before shutdown

```console
$ make cluster-status

[2026-05-25T15:55:30Z] === Azure VM inventory (rg-ocp-lab) ===
ROLE           NAME                                         POWER
master         vm-master-0-lab                              PowerState/running
master         vm-master-1-lab                              PowerState/running
master         vm-master-2-lab                              PowerState/running
worker         vm-worker-0-lab                              PowerState/running
worker         vm-worker-1-lab                              PowerState/running
sriov-worker   vm-worker-sriov-lab                          PowerState/running

[2026-05-25T15:55:32Z] === kubeconfig / cluster context ===
[2026-05-25T15:55:32Z] [INFO]  user:   kube:admin
[2026-05-25T15:55:32Z] [INFO]  server: https://api.lab.ocp.example.com:6443

[2026-05-25T15:55:34Z] === nodes ===
...all Ready...

[2026-05-25T15:55:36Z] === clusteroperators ===
...all Available=True Progressing=False Degraded=False...

[2026-05-25T15:55:38Z] === etcd member health ===
+----------------------------+--------+-------------+-------+
|         ENDPOINT           | HEALTH |    TOOK     | ERROR |
+----------------------------+--------+-------------+-------+
| https://10.20.1.10:2379    |  true  |  9.123456ms |       |
| https://10.20.1.11:2379    |  true  | 10.456789ms |       |
| https://10.20.1.12:2379    |  true  | 11.789012ms |       |
+----------------------------+--------+-------------+-------+

[2026-05-25T15:55:39Z] === certificate expiry ===
[2026-05-25T15:55:39Z] [INFO]  kube-apiserver-to-kubelet-signer not-after: 2026-12-01T08:34:21Z
[2026-05-25T15:55:39Z] [INFO]  (restart the cluster before that date to avoid manual CSR recovery)
```

### Graceful shutdown

```console
$ make cluster-shutdown

[2026-05-25T16:00:00Z] === Azure VM inventory in resource group rg-ocp-lab ===
ROLE           NAME                                         POWER
master         vm-master-0-lab                              PowerState/running
...

[2026-05-25T16:00:01Z] === graceful shutdown ===
[2026-05-25T16:00:01Z] [INFO]  kube-apiserver-to-kubelet signer not-after: 2026-12-01T08:34:21Z
[2026-05-25T16:00:01Z] [INFO]  (restart the cluster before that date to avoid manual CSR recovery)
[2026-05-25T16:00:02Z] [INFO]  running shutdown preflight checks

[2026-05-25T16:00:03Z] === taking etcd backup (use --no-backup to skip) ===
[2026-05-25T16:00:04Z] [INFO]  etcd backup will run on node: master-2.lab.ocp.example.com
[2026-05-25T16:00:04Z] [INFO]  local destination: /home/operator/ocp-multus/backups/20260525T160003Z-lab

[2026-05-25T16:00:08Z] === running /usr/local/bin/cluster-backup.sh on master-2.lab.ocp.example.com ===

[2026-05-25T16:00:42Z] === decoding backup tarball locally ===

[2026-05-25T16:00:43Z] === best-effort cleanup of remote staging directory ===
[2026-05-25T16:00:44Z] [INFO]  etcd backup complete: /home/operator/ocp-multus/backups/20260525T160003Z-lab

Proceed to cordon + drain + shut down the cluster? [y/N] y

[2026-05-25T16:00:51Z] === cordoning all nodes ===
[2026-05-25T16:00:51Z] [INFO]  cordon master-0.lab.ocp.example.com
...

[2026-05-25T16:00:55Z] === draining worker nodes (timeout=15s) ===
[2026-05-25T16:00:55Z] [INFO]  drain worker-0.lab.ocp.example.com
...

[2026-05-25T16:01:42Z] === ordering in-OS shutdown (workers first, deterministic master last) ===
[2026-05-25T16:01:42Z] [INFO]  last master in shutdown order: master-1.lab.ocp.example.com
[2026-05-25T16:01:42Z] [INFO]  (on Azure UPI the API VIP is on a Standard Load Balancer, not a master; this is just a deterministic ordering hint)
[2026-05-25T16:01:43Z] [INFO]  shutdown -h 1 on worker-0.lab.ocp.example.com
...
[2026-05-25T16:01:48Z] [INFO]  shutdown -h 1 on master-1.lab.ocp.example.com

[2026-05-25T16:02:55Z] === waiting for Azure to report all cluster VMs stopped or deallocated ===
[2026-05-25T16:03:16Z] [INFO]  still waiting: vm-master-0-lab=PowerState/running ...
[2026-05-25T16:05:38Z] [INFO]  all target VMs report stopped or deallocated

[2026-05-25T16:05:39Z] === deallocating cluster VMs (releases compute billing; disks/NICs preserved) ===
[2026-05-25T16:05:42Z] [INFO]  deallocate initiated for 6 VMs (running in the background)

[2026-05-25T16:05:42Z] === done ===
[2026-05-25T16:05:42Z] [INFO]  to bring the cluster back up: make cluster-startup
[2026-05-25T16:05:42Z] [INFO]  to bring back only workers:    make workers-up
```

### Restart the next morning

```console
$ make cluster-startup

[2026-05-26T06:30:01Z] === Azure VM inventory in resource group rg-ocp-lab ===
ROLE           NAME                                         POWER
master         vm-master-0-lab                              PowerState/deallocated
...

[2026-05-26T06:30:03Z] === starting control plane VMs ===
[2026-05-26T06:30:03Z] [INFO]  starting 3 master VMs

[2026-05-26T06:32:18Z] === waiting for the Kubernetes API to respond (control plane just started) ===
[2026-05-26T06:32:18Z] [INFO]  waiting up to 45m for Kubernetes API to respond...
[2026-05-26T06:38:50Z] [INFO]  Kubernetes API is reachable
[2026-05-26T06:38:51Z] [INFO]  oc context: kube:admin @ https://api.lab.ocp.example.com:6443

[2026-05-26T06:38:51Z] === approving any pending kubelet CSRs (auto-approval loop) ===
[2026-05-26T06:38:53Z] [INFO]  approving CSRs: csr-aaaaa csr-bbbbb csr-ccccc

[2026-05-26T06:38:53Z] === waiting for control plane nodes to become Ready ===
[2026-05-26T06:38:53Z] [INFO]  waiting up to 45m for nodes node-role.kubernetes.io/master to become Ready...
[2026-05-26T06:42:11Z] [INFO]  nodes node-role.kubernetes.io/master: 3/3 Ready

[2026-05-26T06:42:11Z] === starting worker VMs (including SR-IOV worker) now that control plane is Ready ===
[2026-05-26T06:42:11Z] [INFO]  starting 2 worker VMs
[2026-05-26T06:42:14Z] [INFO]  starting 1 sriov-worker VMs

[2026-05-26T06:43:55Z] === waiting for worker nodes to become Ready ===
[2026-05-26T06:48:33Z] [INFO]  nodes node-role.kubernetes.io/worker: 3/3 Ready

[2026-05-26T06:48:33Z] === uncordoning all nodes ===
[2026-05-26T06:48:33Z] [INFO]  uncordon master-0.lab.ocp.example.com
...

[2026-05-26T06:48:38Z] === waiting for clusteroperators to converge ===
[2026-05-26T06:48:38Z] [INFO]  waiting up to 45m for all clusteroperators to converge...
[2026-05-26T06:55:02Z] [INFO]  all 33 clusteroperators Available / !Progressing / !Degraded

[2026-05-26T06:55:02Z] === etcd health ===
+----------------------------+--------+-------------+-------+
|         ENDPOINT           | HEALTH |    TOOK     | ERROR |
+----------------------------+--------+-------------+-------+
| https://10.20.1.10:2379    |  true  | 10.234567ms |       |
| https://10.20.1.11:2379    |  true  | 11.345678ms |       |
| https://10.20.1.12:2379    |  true  | 12.456789ms |       |
+----------------------------+--------+-------------+-------+

[2026-05-26T06:55:04Z] === summary ===
...oc get nodes -o wide...
...oc get co...
[2026-05-26T06:55:04Z] [INFO]  cluster startup complete
```

A fresh `make cluster-status` should now show everything green again.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `cluster-shutdown` complains "no cluster VMs found" | VM names don't match the pattern in `config/cluster.env` | Set `CONTROL_PLANE_VM_PREFIX` / `WORKER_VM_PREFIX` / `SRIOV_WORKER_VM_NAME` to match what Terraform created. |
| `cluster-shutdown` errors with "expected at least 3 control plane nodes" | Cluster lost masters before shutdown | Investigate first; pass `--no-preflight` only if you know it's safe (e.g. you intentionally have a 1-master lab cluster). |
| `cluster-shutdown` errors "refusing to deallocate VMs that did not gracefully stop" | A node didn't respond to `shutdown -h` within `--timeout` | SSH/console to the node, investigate, then re-run. Or pass `--force-deallocate-after-timeout` if you accept the etcd risk. |
| `oc debug ... shutdown -h 1` returns non-zero | Node already going down, or container couldn't start because kubelet is stressed | Script logs a warning and continues — usually fine. |
| Nodes stuck `NotReady` after startup | Pending CSRs | The startup script auto-approves kubelet CSRs every loop. If something else is pending, run `oc get csr` and inspect. |
| `clusteroperators` won't converge | Workload PVs / storage provider not back yet, or you started workers before masters were healthy | Re-run `make cluster-status`, give it a few minutes. The startup script now waits for masters Ready *before* starting workers, so this should be rare. |
| Cluster has been down > 1 year | kube-apiserver-to-kubelet signer expired | Follow the [expired certificate recovery procedure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/recovering-from-expired-control-plane-certificates). |
| etcd looks unhealthy after restart | One control plane VM started late or was hard-stopped previously | Try `make cluster-status` after a few minutes. If still unhealthy, restore from the most recent etcd backup. |

## Scheduling / automation

For unattended scheduled runs (overnight shutdown, morning startup) see
[`scheduling.md`](./scheduling.md). It covers:

- The recommended GitHub Actions two-workflow pattern (separate shutdown and startup workflows on cron triggers).
- Linux/macOS `cron` with a wrapper script that handles locking and logging.
- `systemd` timer + service unit examples.

If you can't use GitHub Actions (org policy, no GitHub access, Azure-only
control plane), see [`azure-automation.md`](./azure-automation.md) for
Azure-native alternatives: Container Apps Jobs (recommended default),
Azure Automation + Linux Hybrid Worker, plus Functions and Azure DevOps
Pipelines at a glance.

## Out of scope

- Restoring etcd from backup (do this manually with Red Hat's documented procedure).
- Hibernation (this is UPI, not Azure Red Hat OpenShift / ARO — ARO has its own managed hibernation feature).
- Cross-region failover.
- Automated cost reporting.
