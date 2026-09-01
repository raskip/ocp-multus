#!/usr/bin/env bash
# Cross-node host-device Multus demo.
#
# Proves a pod keeps its default eth0 (cluster network / ingress) AND gets a
# second, externally-routable interface (net1) that works ACROSS NODES on Azure.
#
# Mechanism: the standard worker pool already has a secondary NIC on the Multus
# subnet (in-guest eth1) -- a real Azure NIC with a registered MAC and an
# Azure-assigned IP. The host-device CNI moves that whole NIC into one pod per
# node. Because the IP/MAC are Azure-registered, Azure SDN routes the traffic
# natively across nodes and out to the VNet. (macvlan cannot: its synthetic MAC
# is dropped by Azure's SDN -- see docs/multus-validation.md.)
#
# Caveat: while a demo pod runs, that node's eth1 is owned by the pod (one such
# pod per node). That is expected for host-device and fine for this validation.
#
# Requirements: run where `oc` can reach the cluster API. Uses only oc.
# The two workers must each have the Multus secondary NIC (default worker pool,
# CNF_PROFILE=false). Override any default via the env vars below.
set -euo pipefail

OC="${OC:-oc}"
NS="${NS:-hostdev-xnode-demo}"
DEV="${DEV:-eth1}"   # in-guest name of the Multus-subnet NIC (arm64: enP*; verify below)
GW="${GW:-}"         # optional gateway for external egress test; empty = skip gateway
TARGETS="${TARGETS:-}" # optional space-separated Azure/on-prem IPs tested via net1
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
CREATED_NS=0
SUCCESS=0

cleanup() {
  local rc=$?
  if [[ $SUCCESS -eq 0 && "$KEEP_ON_FAILURE" != "1" && $CREATED_NS -eq 1 ]]; then
    echo "==> failed; deleting namespace $NS to return host-device NICs to the nodes" >&2
    "$OC" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
  elif [[ $SUCCESS -eq 0 && "$KEEP_ON_FAILURE" == "1" ]]; then
    echo "==> failed; KEEP_ON_FAILURE=1 leaves namespace $NS for investigation" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

# Pick the two worker nodes (override with NODE_A / NODE_B if needed).
if [[ -z "${NODE_A:-}" || -z "${NODE_B:-}" ]]; then
  mapfile -t _NODES < <("$OC" get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  NODE_A="${NODE_A:-${_NODES[0]:-}}"
  NODE_B="${NODE_B:-${_NODES[1]:-}}"
fi
[[ -n "$NODE_A" && -n "$NODE_B" && "$NODE_A" != "$NODE_B" ]] || {
  echo "ERROR: need two distinct worker nodes (got A='$NODE_A' B='$NODE_B')."
  echo "       Set NODE_A / NODE_B explicitly."; exit 1; }

echo "==> workers: A=$NODE_A  B=$NODE_B  (dev=$DEV)"

if "$OC" get ns "$NS" >/dev/null 2>&1; then
  echo "ERROR: namespace $NS already exists."
  echo "       Delete it first or choose another namespace with NS=<name>."
  exit 1
fi
CREATED_NS=1

# Read the CIDR (ip/prefix) of $DEV on a node via oc debug.
get_cidr() {
  "$OC" debug "node/$1" -- chroot /host ip -4 -o addr show "$DEV" 2>/dev/null \
    | grep -oE 'inet [0-9.]+/[0-9]+' | awk '{print $2}' | head -1
}
CIDR_A="$(get_cidr "$NODE_A" || true)"; CIDR_B="$(get_cidr "$NODE_B" || true)"
[[ -n "$CIDR_A" && -n "$CIDR_B" ]] || {
  echo "ERROR: could not read $DEV address (A='$CIDR_A' B='$CIDR_B')."
  echo "       Confirm the in-guest NIC name: oc debug node/<w> -- chroot /host ip -br a"; exit 1; }
IP_A="${CIDR_A%/*}"
IP_B="${CIDR_B%/*}"
echo "    A $DEV = $CIDR_A"
echo "    B $DEV = $CIDR_B"

# Build the optional gateway fragment.
gw_frag() {
  if [[ -n "$GW" ]]; then
    printf ',"gateway":"%s"' "$GW"
  fi
}

echo "==> applying namespace + host-device NADs + pods"
cat <<EOF | "$OC" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: { name: hostdev-a, namespace: $NS }
spec:
  config: |
    {
      "cniVersion":"0.3.1","name":"hostdev-a","type":"host-device","device":"$DEV",
      "ipam":{"type":"static","addresses":[{"address":"$CIDR_A"$(gw_frag)}]}
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: { name: hostdev-b, namespace: $NS }
spec:
  config: |
    {
      "cniVersion":"0.3.1","name":"hostdev-b","type":"host-device","device":"$DEV",
      "ipam":{"type":"static","addresses":[{"address":"$CIDR_B"$(gw_frag)}]}
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: hostdev-a
  namespace: $NS
  annotations: { k8s.v1.cni.cncf.io/networks: hostdev-a }
spec:
  nodeName: $NODE_A
  containers:
    - name: shell
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["/bin/bash","-c","sleep infinity"]
      securityContext: { capabilities: { add: ["NET_RAW","NET_ADMIN"] } }
---
apiVersion: v1
kind: Pod
metadata:
  name: hostdev-b
  namespace: $NS
  annotations: { k8s.v1.cni.cncf.io/networks: hostdev-b }
spec:
  nodeName: $NODE_B
  containers:
    - name: shell
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["/bin/bash","-c","sleep infinity"]
      securityContext: { capabilities: { add: ["NET_RAW","NET_ADMIN"] } }
EOF

echo "==> waiting for pods"
"$OC" -n "$NS" wait --for=condition=Ready pod/hostdev-a pod/hostdev-b --timeout=180s

echo "==> interfaces on hostdev-a (expect eth0 + net1=$CIDR_A)"
"$OC" -n "$NS" exec hostdev-a -- ip -br a
echo "==> interfaces on hostdev-b (expect eth0 + net1=$CIDR_B)"
"$OC" -n "$NS" exec hostdev-b -- ip -br a

POD_IP_A="$("$OC" -n "$NS" get pod hostdev-a -o jsonpath='{.status.podIP}')"
POD_IP_B="$("$OC" -n "$NS" get pod hostdev-b -o jsonpath='{.status.podIP}')"

echo "==> DEFAULT NETWORK cross-node ping: hostdev-a ($POD_IP_A) -> hostdev-b ($POD_IP_B)"
"$OC" -n "$NS" exec hostdev-a -- ping -c4 "$POD_IP_B"
echo "==> DEFAULT NETWORK reverse ping: hostdev-b ($POD_IP_B) -> hostdev-a ($POD_IP_A)"
"$OC" -n "$NS" exec hostdev-b -- ping -c4 "$POD_IP_A"

echo "==> SECONDARY NETWORK cross-node ping: hostdev-a ($CIDR_A) -> hostdev-b ($IP_B)"
"$OC" -n "$NS" exec hostdev-a -- ping -c4 "$IP_B"
echo "==> SECONDARY NETWORK reverse ping: hostdev-b ($CIDR_B) -> hostdev-a ($IP_A)"
"$OC" -n "$NS" exec hostdev-b -- ping -c4 "$IP_A"

if [[ -n "$GW" ]]; then
  echo "==> gateway test through net1: $GW"
  "$OC" -n "$NS" exec hostdev-a -- ping -I net1 -c4 "$GW"
  "$OC" -n "$NS" exec hostdev-b -- ping -I net1 -c4 "$GW"
fi

read -r -a TARGET_LIST <<< "$TARGETS"
for target in "${TARGET_LIST[@]}"; do
  echo "==> external target through net1: $target"
  "$OC" -n "$NS" exec hostdev-a -- ip route get "$target"
  "$OC" -n "$NS" exec hostdev-a -- ping -I net1 -c4 "$target"
  "$OC" -n "$NS" exec hostdev-b -- ip route get "$target"
  "$OC" -n "$NS" exec hostdev-b -- ping -I net1 -c4 "$target"
done

echo
echo "SUCCESS: default and secondary cross-node checks passed."
[[ -n "$TARGETS" ]] && echo "External net1 targets passed: $TARGETS"
echo "Cleanup:  $OC delete ns $NS"
SUCCESS=1
