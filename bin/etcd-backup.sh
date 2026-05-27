#!/usr/bin/env bash
# Snapshot etcd to the local backups/ directory.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$REPO_ROOT/scripts/cluster-etcd-backup.sh" "$@"
