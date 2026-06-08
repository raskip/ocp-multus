# CNF Multus ipvlan networks (OAM + AUSF-UDM + HSS-HLR)

> **Status: template.** The NADs in this directory ship with **placeholder**
> CIDRs, ipvlan `mode`, IPAM ranges, and `master` interfaces. They are valid
> YAML and apply cleanly, but the values **must be replaced with the ones the
> CNF vendor provides** before the workloads will route correctly. Every
> placeholder is marked `TODO(vendor)` in the file header.

This is the CNF (telco) counterpart to [`manifests/multus/`](../multus/). It
attaches CNF pods to the three dedicated LAN subnets created by the
`enable_cnf_lans` Terraform profile (see
[`docs/cnf-telco-profile.md`](../../docs/cnf-telco-profile.md)).

## Interface mapping (important)

With `enable_cnf_lans = true`, each worker has **four** NICs and the demo
`multus` NIC is dropped, so the in-guest order is:

| NIC | In-guest name (x86_64) | LAN / NAD |
|-----|------------------------|-----------|
| primary | `eth0` | pod/node network (no NAD) |
| oam | `eth1` | `oam-ipvlan` |
| ausfudm | `eth2` | `ausfudm-ipvlan` |
| hsshlr | `eth3` | `hsshlr-ipvlan` |

Always verify the real names (PCI order can vary; arm64 uses `enP*`):

```bash
oc get nodes -l node-role.kubernetes.io/appworker -o name \
  | xargs -I{} oc debug {} -- chroot /host ip -br a
```

Update the `master` field in each NAD if the names differ.

## Apply order

```bash
oc apply -f 00-namespace.yaml
oc adm policy add-scc-to-user privileged -z cnf-sa -n cnf   # or the scoped SCC in ../cnf-platform/
oc apply -f 01-oam-ipvlan-nad.yaml
oc apply -f 02-ausfudm-ipvlan-nad.yaml
oc apply -f 03-hsshlr-ipvlan-nad.yaml
oc apply -f 04-cnf-pod-example.yaml
oc -n cnf rollout status deploy/cnf-example --timeout=5m
oc -n cnf exec deploy/cnf-example -- ip -br a
```

## TODO(vendor) before production

- ipvlan `mode` per LAN: `l2` / `l3` / `l3s`.
- IPAM: `whereabouts` ranges/gateways (inside the LAN CIDRs, not overlapping
  Azure NIC IPs) or `static`.
- Static `routes` for the external LANs (AUSF-UDM / HSS-HLR) to reach peers.
- MTU (default 1500; confirm path MTU — see the profile doc).
- SCTP container ports (requires the `sctp` module from
  [`manifests/node-tuning/`](../node-tuning/)).
