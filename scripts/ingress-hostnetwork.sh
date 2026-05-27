#!/usr/bin/env bash
# scripts/ingress-hostnetwork.sh
#
# Patch the default IngressController to HostNetwork. Use when
# terraform/01-network/ pre-creates an internal apps LB
# (lb-ingress-internal-*) with workers in its backend pool — the default
# LoadBalancerService strategy provisions a second LB and conflicts.
#
# Idempotent: safe to re-run. Waits for `co/ingress` to report Available.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Use the same PATH fallback as scripts/lib/common.sh require_oc.
if ! command -v oc >/dev/null 2>&1 && [[ -x "$REPO_ROOT/oc" ]]; then
  export PATH="$REPO_ROOT:$PATH"
fi
command -v oc >/dev/null 2>&1 || { echo "oc not found on PATH"; exit 1; }

oc whoami >/dev/null 2>&1 || { echo "oc not logged in"; exit 1; }

echo "[*] deleting any existing default IngressController"
oc -n openshift-ingress-operator delete ingresscontroller default --ignore-not-found

echo "[*] creating default IngressController with HostNetwork strategy"
cat <<'EOF' | oc apply -f -
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

echo "[*] waiting for co/ingress to report Available (up to 10m)"
oc wait --for=condition=Available co/ingress --timeout=10m

echo "[*] current ingress operator state:"
oc get co ingress
oc get ingresscontroller -n openshift-ingress-operator default \
  -o jsonpath='{.spec.endpointPublishingStrategy.type}{"\n"}'
