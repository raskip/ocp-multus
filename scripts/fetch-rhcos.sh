#!/usr/bin/env bash
# Resolve the RHCOS aarch64 Azure VHD URL for the installer's release.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/openshift-install" coreos print-stream-json \
  | jq -r '.architectures.aarch64.artifacts.azure.formats."vhd.gz".disk.location
           // .architectures.aarch64.artifacts.azure.formats.vhd.disk.location
           // .architectures.aarch64.images.azure.url'
