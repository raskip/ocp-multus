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
AUTO_INGRESS_HOSTNETWORK="${AUTO_INGRESS_HOSTNETWORK:-true}"

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

auto_ingress_hostnetwork() {
  local deadline strategy
  deadline=$(( $(date +%s) + 45 * 60 ))

  echo "[auto-ingress] waiting for default IngressController to exist..."
  while (( $(date +%s) < deadline )); do
    strategy="$("$OC" get ingresscontroller default -n openshift-ingress-operator \
      -o jsonpath='{.spec.endpointPublishingStrategy.type}' 2>/dev/null || true)"

    case "$strategy" in
      HostNetwork)
        echo "[auto-ingress] default IngressController already uses HostNetwork."
        return 0
        ;;
      LoadBalancerService|"")
        if [[ -n "$strategy" ]]; then
          echo "[auto-ingress] switching default IngressController from $strategy to HostNetwork."
          if "$REPO_ROOT/scripts/ingress-hostnetwork.sh" --no-wait; then
            echo "[auto-ingress] HostNetwork strategy applied."
          else
            echo "[auto-ingress] WARN: automatic HostNetwork conversion failed; if install-complete hangs, run 'make ingress-hostnetwork' manually." >&2
          fi
          return 0
        fi
        ;;
      *)
        echo "[auto-ingress] default IngressController strategy is '$strategy'; leaving it unchanged."
        return 0
        ;;
    esac

    sleep 15
  done

  echo "[auto-ingress] WARN: default IngressController was not observed before timeout; if install-complete hangs, run 'make ingress-hostnetwork' manually." >&2
}

# Background the CSR-approver; ensure it dies when this script exits.
approve_loop &
APPROVER_PID=$!
INGRESS_PID=""
cleanup() {
  kill "$APPROVER_PID" 2>/dev/null || true
  if [[ -n "$INGRESS_PID" ]]; then
    kill "$INGRESS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[wait-install] CSR approver started (pid=$APPROVER_PID)."
case "${AUTO_INGRESS_HOSTNETWORK,,}" in
  1|true|yes|y)
    auto_ingress_hostnetwork &
    INGRESS_PID=$!
    echo "[wait-install] Auto HostNetwork ingress helper started (pid=$INGRESS_PID)."
    ;;
  *)
    echo "[wait-install] Auto HostNetwork ingress helper disabled (AUTO_INGRESS_HOSTNETWORK=$AUTO_INGRESS_HOSTNETWORK)."
    ;;
esac

echo "[wait-install] Waiting for install-complete (may take 15-25 min)..."
"$INSTALLER" --dir="$INSTALL_DIR" wait-for install-complete --log-level=info "$@"
