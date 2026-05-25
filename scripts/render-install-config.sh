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
  SERVICE_NETWORK_CIDR CONTROL_PLANE_VM_SIZE WORKER_VM_SIZE PUBLISH
  PULL_SECRET_FILE SSH_PUBLIC_KEY_FILE
)

for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "missing required config value: $var"; exit 1; }
done

pull_secret_path="$REPO_ROOT/$PULL_SECRET_FILE"
ssh_pub_path="$REPO_ROOT/$SSH_PUBLIC_KEY_FILE"

[[ -f "$pull_secret_path" ]] || { echo "missing $pull_secret_path"; exit 1; }
[[ -f "$ssh_pub_path" ]] || { echo "missing $ssh_pub_path"; exit 1; }

PULL_SECRET="$(tr -d '\n' < "$pull_secret_path")"
SSH_PUB="$(cat "$ssh_pub_path")"

export PULL_SECRET SSH_PUB
perl -0pe '
  s/__BASE_DOMAIN__/$ENV{BASE_DOMAIN}/g;
  s/__CLUSTER_NAME__/$ENV{CLUSTER_NAME}/g;
  s/__LOCATION__/$ENV{LOCATION}/g;
  s/__DNS_RESOURCE_GROUP__/$ENV{DNS_RESOURCE_GROUP}/g;
  s/__NETWORK_RESOURCE_GROUP__/$ENV{NETWORK_RESOURCE_GROUP}/g;
  s/__WORKLOAD_RESOURCE_GROUP__/$ENV{WORKLOAD_RESOURCE_GROUP}/g;
  s/__VIRTUAL_NETWORK__/$ENV{VIRTUAL_NETWORK}/g;
  s/__CONTROL_PLANE_SUBNET__/$ENV{CONTROL_PLANE_SUBNET}/g;
  s/__COMPUTE_SUBNET__/$ENV{COMPUTE_SUBNET}/g;
  s/__MACHINE_NETWORK_CIDR__/$ENV{MACHINE_NETWORK_CIDR}/g;
  s/__CLUSTER_NETWORK_CIDR__/$ENV{CLUSTER_NETWORK_CIDR}/g;
  s/__CLUSTER_NETWORK_HOST_PREFIX__/$ENV{CLUSTER_NETWORK_HOST_PREFIX}/g;
  s/__SERVICE_NETWORK_CIDR__/$ENV{SERVICE_NETWORK_CIDR}/g;
  s/__CONTROL_PLANE_VM_SIZE__/$ENV{CONTROL_PLANE_VM_SIZE}/g;
  s/__WORKER_VM_SIZE__/$ENV{WORKER_VM_SIZE}/g;
  s/__PUBLISH__/$ENV{PUBLISH}/g;
  s/__PULL_SECRET__/$ENV{PULL_SECRET}/g;
  s/__SSH_PUBLIC_KEY__/$ENV{SSH_PUB}/g;
' "$TMPL" > "$OUT"

chmod 600 "$OUT"
echo "Wrote $OUT"
