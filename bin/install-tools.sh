#!/usr/bin/env bash
# Download openshift-install + oc into the repo root (calls `make tools`).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec make -C "$REPO_ROOT" tools "$@"
