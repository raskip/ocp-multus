#!/usr/bin/env bash
# Start a parked cluster: bring VMs back, wait for the K8s API, approve
# CSRs, wait for control-plane Ready, then workers Ready, uncordon.
# Passes arguments straight through (--timeout, etc.).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$REPO_ROOT/scripts/cluster-startup.sh" "$@"
