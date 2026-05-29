#!/usr/bin/env bash
# scripts/ingress-hostnetwork.sh
#
# Patch the default IngressController to HostNetwork. Use when
# terraform/01-network/ pre-creates an internal apps LB
# (lb-ingress-internal-*) with workers in its backend pool — the default
# LoadBalancerService strategy provisions a second LB and conflicts.
#
# Idempotent: safe to re-run. By default waits for `co/ingress` to report
# Available; pass --no-wait when called from wait-install because
# openshift-install is already the foreground waiter.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WAIT_FOR_AVAILABLE=1

while (( $# > 0 )); do
  case "$1" in
    --no-wait)
      WAIT_FOR_AVAILABLE=0
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/ingress-hostnetwork.sh [--no-wait]

Recreate the default IngressController with HostNetwork strategy.
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Use the same PATH fallback as scripts/lib/common.sh require_oc.
if ! command -v oc >/dev/null 2>&1 && [[ -x "$REPO_ROOT/oc" ]]; then
  export PATH="$REPO_ROOT:$PATH"
fi
command -v oc >/dev/null 2>&1 || { echo "oc not found on PATH"; exit 1; }

oc whoami >/dev/null 2>&1 || { echo "oc not logged in"; exit 1; }

current_strategy() {
  oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.endpointPublishingStrategy.type}' 2>/dev/null || true
}

if [[ "$(current_strategy)" == "HostNetwork" ]]; then
  echo "[*] default IngressController already uses HostNetwork"
  exit 0
fi

create_hostnetwork() {
  cat <<'EOF' | oc create -f -
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  replicas: 2
  endpointPublishingStrategy:
    type: HostNetwork
EOF
}

for attempt in 1 2 3 4 5; do
  echo "[*] configuring default IngressController as HostNetwork (attempt $attempt/5)"
  oc -n openshift-ingress-operator delete ingresscontroller default \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true

  if create_hostnetwork; then
    :
  else
    echo "[WARN] HostNetwork create failed; checking whether the operator recreated default first" >&2
  fi

  sleep 5
  if [[ "$(current_strategy)" == "HostNetwork" ]]; then
    echo "[*] default IngressController now uses HostNetwork"
    break
  fi

  if (( attempt == 5 )); then
    echo "[ERROR] default IngressController did not converge to HostNetwork" >&2
    exit 1
  fi
done

if (( WAIT_FOR_AVAILABLE == 1 )); then
  echo "[*] waiting for co/ingress to report Available (up to 10m)"
  oc wait --for=condition=Available co/ingress --timeout=10m
fi

echo "[*] current ingress operator state:"
oc get co ingress
oc get ingresscontroller -n openshift-ingress-operator default \
  -o jsonpath='{.spec.endpointPublishingStrategy.type}{"\n"}'
