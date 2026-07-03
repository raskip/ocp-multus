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

# Read the CIDR (ip/prefix) of $DEV on a node via oc debug.
get_cidr() {
  "$OC" debug "node/$1" -- chroot /host ip -4 -o addr show "$DEV" 2>/dev/null \
    | grep -oE 'inet [0-9.]+/[0-9]+' | awk '{print $2}' | head -1
}
CIDR_A="$(get_cidr "$NODE_A")"; CIDR_B="$(get_cidr "$NODE_B")"
[[ -n "$CIDR_A" && -n "$CIDR_B" ]] || {
  echo "ERROR: could not read $DEV address (A='$CIDR_A' B='$CIDR_B')."
  echo "       Confirm the in-guest NIC name: oc debug node/<w> -- chroot /host ip -br a"; exit 1; }
IP_B="${CIDR_B%/*}"
echo "    A $DEV = $CIDR_A"
echo "    B $DEV = $CIDR_B"

# Build the optional gateway fragment.
gw_frag() { [[ -n "$GW" ]] && printf ',"gateway":"%s"' "$GW" || true; }

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

echo "==> CROSS-NODE ping: hostdev-a ($CIDR_A) -> hostdev-b ($IP_B)"
"$OC" -n "$NS" exec hostdev-a -- ping -c4 "$IP_B"

if [[ -n "$GW" ]]; then
  echo "==> external egress test via net1 gateway $GW (optional; may be NSG-blocked)"
  "$OC" -n "$NS" exec hostdev-a -- ping -c2 "$GW" || echo "   (gateway ping optional)"
fi

echo
echo "SUCCESS if the cross-node ping above replied."
echo "Cleanup:  $OC delete ns $NS"
