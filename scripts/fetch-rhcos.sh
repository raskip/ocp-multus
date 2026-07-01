#!/usr/bin/env bash
# Resolve the RHCOS Azure VHD URL for the installer's release.
# Architecture is taken from config/cluster.env (ARCHITECTURE=x86_64|arm64).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"

[[ -f "$CONFIG_FILE" ]] || { echo "missing $CONFIG_FILE (copy config/cluster.example.env first)" >&2; exit 1; }
# shellcheck source=/dev/null
ARCHITECTURE="$(grep -E '^ARCHITECTURE=' "$CONFIG_FILE" | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
ARCHITECTURE="${ARCHITECTURE:-x86_64}"

case "$ARCHITECTURE" in
  x86_64) RHCOS_ARCH=x86_64 ;;
  arm64)  RHCOS_ARCH=aarch64 ;;
  *)
    echo "Unsupported ARCHITECTURE='$ARCHITECTURE' (expected: x86_64 | arm64)" >&2
    exit 1
    ;;
esac

"$REPO_ROOT/openshift-install" coreos print-stream-json \
  | jq -r --arg arch "$RHCOS_ARCH" '
      .architectures[$arch].artifacts.azure.formats."vhd.gz".disk.location
      // .architectures[$arch].artifacts.azure.formats.vhd.disk.location
      // .architectures[$arch].images.azure.url'
