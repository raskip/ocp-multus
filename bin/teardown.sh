#!/usr/bin/env bash
# Destroy the cluster and all Terraform-managed resources. Equivalent to
# `make destroy`. NOTE: only purges what the repo created — Day-1 network
# prereqs (VNet, peerings, parent DNS zone, etc.) remain.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec make -C "$REPO_ROOT" destroy "$@"
