# Per-script CLI reference

One page per lifecycle script. Each page lists the synopsis, full flag
set, environment variables, examples, and exit codes for that script.

For the operational story (when to use which, cost model, full
walkthrough) see [`operations.md`](../operations.md). For unattended
scheduled runs see [`scheduling.md`](../scheduling.md).

| Script | Purpose |
|---|---|
| [`cluster-shutdown.md`](./cluster-shutdown.md) | Graceful (or fast) shutdown + Azure deallocate of the full cluster. |
| [`cluster-startup.md`](./cluster-startup.md) | Start the cluster back up: VMs, CSRs, uncordon, wait healthy. |
| [`cluster-etcd-backup.md`](./cluster-etcd-backup.md) | Take an etcd snapshot via `oc debug` and copy it locally. |
| [`cluster-scale-workers.md`](./cluster-scale-workers.md) | Stop/start only workers; control plane stays up. |
| [`cluster-status.md`](./cluster-status.md) | Read-only health snapshot. |
