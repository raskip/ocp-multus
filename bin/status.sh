#!/usr/bin/env bash
# Print a cluster + Azure power-state summary. Equivalent to `make cluster-status`.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec make -C "$REPO_ROOT" cluster-status "$@"
