#!/usr/bin/env bash
# Render install-config/install-config.yaml from config/cluster.env and secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$REPO_ROOT/install-config/install-config.yaml.tmpl"
OUT="$REPO_ROOT/install-config/install-config.yaml"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"

[[ -f "$TMPL" ]] || { echo "missing $TMPL"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "missing $CONFIG_FILE (copy config/cluster.example.env first)"; exit 1; }

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

required_vars=(
  CLUSTER_NAME BASE_DOMAIN LOCATION DNS_RESOURCE_GROUP NETWORK_RESOURCE_GROUP
  WORKLOAD_RESOURCE_GROUP VIRTUAL_NETWORK CONTROL_PLANE_SUBNET COMPUTE_SUBNET
  MACHINE_NETWORK_CIDR CLUSTER_NETWORK_CIDR CLUSTER_NETWORK_HOST_PREFIX
  SERVICE_NETWORK_CIDR ARCHITECTURE CONTROL_PLANE_VM_SIZE WORKER_VM_SIZE PUBLISH
  PULL_SECRET_FILE SSH_PUBLIC_KEY_FILE
)

for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "missing required config value: $var"; exit 1; }
done

case "$ARCHITECTURE" in
  x86_64) ARCHITECTURE_OCP=amd64 ;;
  arm64)  ARCHITECTURE_OCP=arm64 ;;
  *)
    echo "Unsupported ARCHITECTURE='$ARCHITECTURE' (expected: x86_64 | arm64)"
    exit 1
    ;;
esac

pull_secret_path="$REPO_ROOT/$PULL_SECRET_FILE"
ssh_pub_path="$REPO_ROOT/$SSH_PUBLIC_KEY_FILE"

[[ -f "$pull_secret_path" ]] || { echo "missing $pull_secret_path"; exit 1; }
[[ -f "$ssh_pub_path" ]] || { echo "missing $ssh_pub_path"; exit 1; }

PULL_SECRET="$(tr -d '\n' < "$pull_secret_path")"
SSH_PUB="$(cat "$ssh_pub_path")"

# Substitute __VAR__ placeholders in the template using pure bash parameter
# expansion. Bash's `${var//pattern/replacement}` does literal substitution
# so JSON pull secrets containing `/`, `"`, or `$` characters are handled
# safely without escaping. We disable `patsub_replacement` (bash 5.2+) so
# `&` and `\` in the replacement remain literal, matching pre-5.2 behavior
# (and the behavior of the older `perl -0pe` implementation this replaced).
# The option may not exist on bash < 5.2; `|| true` makes that a no-op.
shopt -u patsub_replacement 2>/dev/null || true

TPL="$(cat "$TMPL")"
TPL="${TPL//__BASE_DOMAIN__/$BASE_DOMAIN}"
TPL="${TPL//__CLUSTER_NAME__/$CLUSTER_NAME}"
TPL="${TPL//__LOCATION__/$LOCATION}"
TPL="${TPL//__DNS_RESOURCE_GROUP__/$DNS_RESOURCE_GROUP}"
TPL="${TPL//__NETWORK_RESOURCE_GROUP__/$NETWORK_RESOURCE_GROUP}"
TPL="${TPL//__WORKLOAD_RESOURCE_GROUP__/$WORKLOAD_RESOURCE_GROUP}"
TPL="${TPL//__VIRTUAL_NETWORK__/$VIRTUAL_NETWORK}"
TPL="${TPL//__CONTROL_PLANE_SUBNET__/$CONTROL_PLANE_SUBNET}"
TPL="${TPL//__COMPUTE_SUBNET__/$COMPUTE_SUBNET}"
TPL="${TPL//__MACHINE_NETWORK_CIDR__/$MACHINE_NETWORK_CIDR}"
TPL="${TPL//__CLUSTER_NETWORK_CIDR__/$CLUSTER_NETWORK_CIDR}"
TPL="${TPL//__CLUSTER_NETWORK_HOST_PREFIX__/$CLUSTER_NETWORK_HOST_PREFIX}"
TPL="${TPL//__SERVICE_NETWORK_CIDR__/$SERVICE_NETWORK_CIDR}"
TPL="${TPL//__ARCHITECTURE_OCP__/$ARCHITECTURE_OCP}"
TPL="${TPL//__CONTROL_PLANE_VM_SIZE__/$CONTROL_PLANE_VM_SIZE}"
TPL="${TPL//__WORKER_VM_SIZE__/$WORKER_VM_SIZE}"
TPL="${TPL//__PUBLISH__/$PUBLISH}"
TPL="${TPL//__PULL_SECRET__/$PULL_SECRET}"
TPL="${TPL//__SSH_PUBLIC_KEY__/$SSH_PUB}"
printf '%s\n' "$TPL" > "$OUT"

chmod 600 "$OUT"
echo "Wrote $OUT"
