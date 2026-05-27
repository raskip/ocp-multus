#!/usr/bin/env bash
# Wait for the OpenShift install to complete while approving worker CSRs in
# the background. Kubelet creates two CSRs per worker (client + serving)
# that must be approved before the worker can fully register and the
# install-complete signal can be issued.
#
# Usage: scripts/wait-install.sh [--timeout 45m]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="${OC:-$REPO_ROOT/oc}"
INSTALLER="${INSTALLER:-$REPO_ROOT/openshift-install}"
INSTALL_DIR="${INSTALL_DIR:-$REPO_ROOT/install}"
KUBECONFIG="${KUBECONFIG:-$INSTALL_DIR/auth/kubeconfig}"
export KUBECONFIG

[[ -x "$INSTALLER" ]] || { echo "missing openshift-install at $INSTALLER (run 'make tools')" >&2; exit 1; }
[[ -x "$OC" ]] || { echo "missing oc at $OC (run 'make tools')" >&2; exit 1; }
[[ -d "$INSTALL_DIR" ]] || { echo "missing $INSTALL_DIR (run 'make ignition')" >&2; exit 1; }

approve_loop() {
  while true; do
    pending="$("$OC" get csr -o json 2>/dev/null \
      | jq -r '.items[] | select(.status.conditions == null) | .metadata.name' 2>/dev/null || true)"
    if [[ -n "$pending" ]]; then
      echo "[wait-install] approving CSRs: $(echo "$pending" | tr '\n' ' ')"
      echo "$pending" | xargs -r "$OC" adm certificate approve >/dev/null 2>&1 || true
    fi
    sleep 20
  done
}

# Background the CSR-approver; ensure it dies when this script exits.
approve_loop &
APPROVER_PID=$!
trap 'kill "$APPROVER_PID" 2>/dev/null || true' EXIT

echo "[wait-install] CSR approver started (pid=$APPROVER_PID)."
echo "[wait-install] Waiting for install-complete (may take 15-25 min)..."
"$INSTALLER" --dir="$INSTALL_DIR" wait-for install-complete --log-level=info "$@"
