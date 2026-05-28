# DNS layout migration (B62)

> **TL;DR.** New installs work out of the box (no action needed). If you
> have an existing cluster created before the B62 fix and the install
> succeeded for you, your private DNS zone is in the **legacy layout**;
> keep it that way by setting `USE_LEGACY_DNS_LAYOUT=true` in
> `config/cluster.env` before re-running `terraform apply`.

## What changed

The cluster's private DNS zone now defaults to **new layout**:

| | Legacy layout | New layout (default) |
|---|---|---|
| Zone name | `${base_domain}` (e.g. `ocp.example.com`) | `${cluster_name}.${base_domain}` (e.g. `lab.ocp.example.com`) |
| `api` record name | `api.${cluster_name}` | `api` |
| `api-int` record name | `api-int.${cluster_name}` | `api-int` |
| `*.apps` record name | `*.apps.${cluster_name}` | `*.apps` |
| Resulting FQDN | `api.lab.ocp.example.com` | `api.lab.ocp.example.com` |

The FQDN is identical in both layouts. The difference is **where** the
records live: in the new layout they live in their own per-cluster
subzone (which is also what `openshift-install`'s ingress-operator
expects when it manages the `*.apps` records itself).

## Why the change

OpenShift's ingress-operator (`openshift-ingress-operator` /
`dns-controller`) creates and updates the `*.apps` DNS records itself.
It looks for the cluster's private DNS zone by **exact name match** on
`${cluster_name}.${base_domain}`. With the legacy layout it can't find
a zone with that name, the records never get written, and the install
hangs at `openshift-install wait-for install-complete` with the
`ingress` ClusterOperator stuck in `Available=False, Degraded=True`.

## New installs

No action required. The default (`USE_LEGACY_DNS_LAYOUT=false`) is
already correct.

## Existing installs (created before the B62 fix)

If your existing cluster works (its `*.apps` records were written by
something other than the ingress-operator, e.g. via the bootstrap
ignition fallback or a manual `oc patch`), keep the legacy layout in
your config:

```bash
# config/cluster.env
USE_LEGACY_DNS_LAYOUT=true
```

Then `make tfvars` (and any subsequent `terraform plan/apply`) will
keep your existing zone resource untouched.

### Migrating an existing cluster to the new layout

This is **destructive** — the private DNS zone is a Terraform resource
that gets renamed on change, which means destroy + create. Any external
DNS forwarder or peered network that pins the zone resource ID will
break.

If you really want to migrate (e.g. you've been managing `*.apps`
manually and want to hand it over to the ingress-operator), do this
during a planned maintenance window:

1. Snapshot all current records so you can recreate any custom ones.
2. `USE_LEGACY_DNS_LAYOUT=false` in `config/cluster.env`.
3. `make tfvars`.
4. `cd terraform/00-prereqs && terraform plan` — verify it shows
   `azurerm_private_dns_zone.cluster` being replaced and
   `azurerm_private_dns_a_record.api|api_int|apps` (in 01-network)
   being moved to the new zone.
5. `cd terraform/01-network && terraform plan` — same.
6. Apply both stacks (`terraform apply` each).
7. Re-link the new zone to any VNets that were peered to the old zone.
8. Force `oc -n openshift-ingress-operator rollout restart deploy/ingress-operator`
   so it picks up the new zone and rewrites `*.apps`.

If you don't need the ingress-operator to manage `*.apps` for you (e.g.
you have an external DNS-as-code system already doing this), there's no
operational benefit to migrating — stay on the legacy layout.

## Reference

* `terraform/00-prereqs/variables.tf` — `use_legacy_dns_layout` (full
  docstring).
* `terraform/00-prereqs/main.tf` — `azurerm_private_dns_zone.cluster`
  uses `local.cluster_private_dns_zone_name`.
* `terraform/01-network/main.tf` — `azurerm_private_dns_a_record.{api,
  api_int, apps}` use `local.cluster_dns_zone_name` and the conditional
  record names.
* `scripts/preflight/06-dns-zone.sh` — warns when
  `USE_LEGACY_DNS_LAYOUT=true` is set.
