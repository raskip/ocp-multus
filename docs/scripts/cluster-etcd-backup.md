# `scripts/cluster-etcd-backup.sh`

Take an etcd backup from a Ready control plane node and copy the
artifacts back to the local repo. Wraps the in-cluster
`/usr/local/bin/cluster-backup.sh` script that ships with the
OpenShift control plane image.

## Synopsis

```text
scripts/cluster-etcd-backup.sh [--node <name>] [--out <dir>] [--dry-run]
```

## What it does

1. Pick a Ready control plane node (`--node` lets you override).
2. Run `/usr/local/bin/cluster-backup.sh` inside that node via
   `oc debug node/<name> -- chroot /host`.
3. Tar the resulting directory and stream it back as base64 over stdout
   (all status chatter is redirected to stderr so the tarball is
   never corrupted).
4. Decode and extract locally under `${BACKUP_DIR:-backups}/<UTC-timestamp>-<CLUSTER_NAME>/`
   (override with `--out`).
5. Verify the expected files exist before declaring success.

## Output layout

```
backups/20260525T080000Z-lab/
├── snapshot_2026-05-25_080013.db
├── static_kuberesources_2026-05-25_080013.tar.gz
└── metadata.json
```

`metadata.json` records the cluster name, source node, and timestamp so
you can identify the backup later. `.gitignore` excludes
`backups/*` except `.gitkeep`, so backups never end up in git history.

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--node <name>` | first Ready master | Pick a specific node for the backup. Useful if you suspect one master is the source of truth. |
| `--out <dir>` | `$BACKUP_DIR/<UTC-timestamp>-<CLUSTER_NAME>` | Override the destination directory. |
| `--dry-run` | off | Print what would happen. No changes. |
| `-h`, `--help` | — | Show the usage block from the script header. |

## Environment variables

- `BACKUP_DIR` — root of the backup directory tree (default `backups`).
- `CLUSTER_NAME` — used in the auto-generated destination directory.

Plus the standard `oc` / `az` configuration (the script needs a working
`oc` context to run `oc debug` against the cluster).

## Examples

```bash
# Default: pick a Ready master, backup into backups/<ts>-<cluster>/
bash scripts/cluster-etcd-backup.sh

# Force a specific master
bash scripts/cluster-etcd-backup.sh --node master-1.lab.ocp.example.com

# Custom output directory
bash scripts/cluster-etcd-backup.sh --out /mnt/nfs/etcd-backups/lab/$(date -u +%FT%TZ)

# Verify the script picks a node and computes the right path
bash scripts/cluster-etcd-backup.sh --dry-run
```

## Restore

This script intentionally does NOT restore. Etcd restore is a sensitive
operation that can lose data if done wrong; follow Red Hat's
[control plane backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore)
procedure manually.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Backup taken and verified locally. |
| 1 | Could not select a Ready master, the remote backup produced no output, or the expected files are missing. |
| 2 | Unknown flag / bad invocation. |

## Related

- [`cluster-shutdown.sh`](./cluster-shutdown.md) — calls this automatically before deallocate.
- [`cluster-status.sh`](./cluster-status.md)
- [`operations.md`](../operations.md)
