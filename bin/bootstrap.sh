#!/usr/bin/env bash
# Provision the cluster from scratch. Equivalent to `make all`.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec make -C "$REPO_ROOT" all "$@"
