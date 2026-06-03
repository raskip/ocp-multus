#!/usr/bin/env bash
# Download matching openshift-install + oc binaries for the current host.
#
# Detects host OS + CPU via uname and downloads the matching tarballs from
# mirror.openshift.com to the repo root as ./openshift-install and ./oc.
#
# Override the channel/version via env:
#   OCP_VERSION=stable-4.18       (default — matches the rest of this repo)
#   OCP_VERSION=stable
#   OCP_VERSION=stable-4.19
#   OCP_VERSION=4.18.41
#
# Usage:
#   bash scripts/fetch-openshift-tools.sh           # idempotent; skip if both exist
#   bash scripts/fetch-openshift-tools.sh --force   # re-download even if present
#   OCP_VERSION=stable-4.19 bash scripts/fetch-openshift-tools.sh --force
#
# Important: the host CPU you run this script on only affects which TARBALL is
# downloaded. The deployed OpenShift cluster's CPU is independent and is
# controlled by ARCHITECTURE in config/cluster.env. See CPU-docs/architecture.md.
#
# Requires: bash, curl, tar (gzip-aware).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCP_VERSION="${OCP_VERSION:-stable-4.18}"
MIRROR_BASE="${MIRROR_BASE:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp}"
FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

host_os="$(uname -s)"
host_machine="$(uname -m)"

case "$host_os" in
  Linux)  os_tag="linux" ;;
  Darwin) os_tag="mac" ;;
  MINGW*|MSYS*|CYGWIN*)
    cat >&2 <<'EOF'
ERROR: Native Windows is not supported by openshift-install upstream
       (no openshift-install-windows release on mirror.openshift.com).

Options:
  - Run this repo under WSL2 (Ubuntu/Debian).
  - Run this repo from Azure Cloud Shell.
  - Run this repo from a Linux dev container or GitHub Codespaces.

Note: the 'oc' client IS available for Windows (openshift-client-windows.zip)
      but the 'openshift-install' binary is not. The Makefile in this repo
      uses /bin/bash and bash scripts throughout.
EOF
    exit 1
    ;;
  *)
    echo "ERROR: unsupported host OS: $host_os" >&2
    exit 1
    ;;
esac

case "$host_machine" in
  x86_64|amd64)
    arch_suffix=""        # mirror filename has no arch suffix for x86_64
    arch_label="x86_64"
    ;;
  aarch64|arm64)
    arch_suffix="-arm64"
    arch_label="arm64"
    ;;
  *)
    echo "ERROR: unsupported host CPU: $host_machine (expected x86_64/amd64 or aarch64/arm64)" >&2
    exit 1
    ;;
esac

installer_tarball="openshift-install-${os_tag}${arch_suffix}.tar.gz"
client_tarball="openshift-client-${os_tag}${arch_suffix}.tar.gz"
installer_url="${MIRROR_BASE}/${OCP_VERSION}/${installer_tarball}"
client_url="${MIRROR_BASE}/${OCP_VERSION}/${client_tarball}"

echo "Host detected: ${host_os} / ${host_machine}  ->  ${os_tag}${arch_suffix} (${arch_label})"
echo "OCP channel  : ${OCP_VERSION}"
echo "Installer URL: ${installer_url}"
echo "Client URL   : ${client_url}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry-run: not downloading)"
  exit 0
fi

cd "$REPO_ROOT"

# Warn loudly when a non-default OCP_VERSION is requested but binaries already
# exist — without --force we will keep the existing binaries, which may be a
# different version.
if [[ "$FORCE" -eq 0 && "$OCP_VERSION" != "stable-4.18" ]]; then
  if [[ -x ./openshift-install || -x ./oc ]]; then
    {
      echo
      echo "WARNING: OCP_VERSION='${OCP_VERSION}' was requested, but existing"
      echo "         ./openshift-install or ./oc were found and will be REUSED."
      echo "         Re-run with --force to actually pull ${OCP_VERSION}."
      echo
    } >&2
  fi
fi

need_installer=1
need_client=1
if [[ "$FORCE" -eq 0 ]]; then
  if [[ -x ./openshift-install ]]; then
    echo "openshift-install already present (use --force to re-download)"
    need_installer=0
  fi
  if [[ -x ./oc ]]; then
    echo "oc already present (use --force to re-download)"
    need_client=0
  fi
fi

if [[ "$need_installer" -eq 0 && "$need_client" -eq 0 ]]; then
  echo
  ./openshift-install version
  ./oc version --client
  exit 0
fi

# Atomic download + extract: stage into a tempdir, validate, then move into
# place. Avoids leaving a corrupt binary if curl truncates or tar fails.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

fetch_and_stage() {
  # $1 url   $2 inner-binary-name (openshift-install or oc)
  local url="$1" binary="$2" tarball
  tarball="$(basename "$url")"
  echo "Downloading ${tarball} ..."
  curl -fL --retry 3 -o "${STAGE_DIR}/${tarball}" "${url}"
  tar -C "${STAGE_DIR}" -xzf "${STAGE_DIR}/${tarball}" "${binary}"
  chmod +x "${STAGE_DIR}/${binary}"
  # Sanity-check the staged binary runs before swapping it in.
  "${STAGE_DIR}/${binary}" version >/dev/null 2>&1 \
    || "${STAGE_DIR}/${binary}" version --client >/dev/null 2>&1 \
    || { echo "ERROR: staged ${binary} failed --version check" >&2; exit 1; }
  rm -f "${STAGE_DIR}/${tarball}"
}

if [[ "$need_installer" -eq 1 ]]; then
  fetch_and_stage "${installer_url}" openshift-install
  mv -f "${STAGE_DIR}/openshift-install" ./openshift-install
fi

if [[ "$need_client" -eq 1 ]]; then
  fetch_and_stage "${client_url}" oc
  mv -f "${STAGE_DIR}/oc" ./oc
fi

echo
./openshift-install version
./oc version --client
echo
echo "Done. ./openshift-install and ./oc are ready at ${REPO_ROOT}."
echo "Reminder: the cluster CPU architecture is independent — set ARCHITECTURE in config/cluster.env."