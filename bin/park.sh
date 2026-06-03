#!/usr/bin/env bash
# Park the cluster: drain workers, gracefully shut down every node, then
# deallocate the VMs (state preserved, compute cost ~0). Passes arguments
# straight through to scripts/cluster-shutdown.sh (--no-backup, --yes,
# --drain-timeout, --shutdown-delay-min, --timeout, etc.). Calls the
# script directly so flags are honoured without going through make.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$REPO_ROOT/scripts/cluster-shutdown.sh" "$@"
