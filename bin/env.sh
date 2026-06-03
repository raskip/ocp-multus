#!/usr/bin/env bash
# Source me, do not execute me:
#   source ./bin/env.sh
#
# Sets KUBECONFIG, PATH, and OC/INSTALLER so the repo's `oc` and
# `openshift-install` binaries (downloaded by `make tools`) win over
# anything else on PATH. Honours an existing AZURE_CONFIG_DIR if set.

# Detect direct execution and refuse: when sourced, $0 is the sourcing
# shell ("bash"), not "env.sh". $BASH_SOURCE[0] is always the script path.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo "env.sh must be sourced, not executed: 'source ./bin/env.sh'" >&2
  exit 1
fi

_OCP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="$_OCP_REPO_ROOT:$PATH"
export OC="$_OCP_REPO_ROOT/oc"
export INSTALLER="$_OCP_REPO_ROOT/openshift-install"
export INSTALL_DIR="$_OCP_REPO_ROOT/install"

if [[ -f "$INSTALL_DIR/auth/kubeconfig" ]]; then
  export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
fi

unset _OCP_REPO_ROOT
