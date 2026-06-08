#!/usr/bin/env bash
# Label CNF worker nodes so the `appworker` MachineConfigPool selects them and
# the Phase D node-tuning MachineConfigs land only on these nodes.
#
# Usage:
#   scripts/label-cnf-nodes.sh <node-name> [<node-name> ...]
#
# List candidate workers with:
#   oc get nodes -l node-role.kubernetes.io/worker
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <node-name> [<node-name> ...]" >&2
  echo "tip: oc get nodes -l node-role.kubernetes.io/worker" >&2
  exit 1
fi

for node in "$@"; do
  oc label node "$node" node-role.kubernetes.io/appworker="" --overwrite
  oc label node "$node" is_worker="true" --overwrite
  oc label node "$node" is_edge="true" --overwrite
done

echo "Labelled appworker nodes: $*"
echo "Watch the pool converge with: oc get mcp appworker -w"
