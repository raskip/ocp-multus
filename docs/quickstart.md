# Quickstart

A one-page customer flow for installing OpenShift on Azure with this repo.
Assumes a WSL2 / Linux / macOS shell with `bash`, `make`, `jq`, `az`,
`terraform` already on PATH, and an Azure subscription where you can
create resources.

See [DEMO.md](../DEMO.md) for the full step-by-step runbook, including
the canonical install order and detailed troubleshooting. This doc is the
short version for first-time installers.

## 0. Clone the repo

```bash
git clone https://github.com/raskip/ocp-multus.git
cd ocp-multus
```

## 1. Download the OpenShift CLIs

```bash
make tools          # downloads matching openshift-install + oc into ./
```

## 2. Provide the cluster pull secret + SSH key

The pull secret is **architecture-neutral** — the same JSON works for
x86_64, arm64, Power, and Z. Download yours from
<https://console.redhat.com/openshift/install/pull-secret>.

```bash
mkdir -p secrets
# paste your downloaded pull secret into secrets/pull-secret.txt
ssh-keygen -t ed25519 -f secrets/id_ed25519 -N ''   # cluster SSH key
```

## 3. Create config/cluster.env (interactive wizard)

```bash
make init-config
```

The wizard prompts for ~12 fields with sensible defaults. You can edit
`config/cluster.env` later — it is the single source of truth that feeds
every Terraform stack and shell script. Rerun with `make init-config FORCE=1`
to overwrite an existing file.

## 4. Authenticate to Azure

```bash
./bin/login.sh      # uses env-var SP > ~/.azure/osServicePrincipal.json > device-code
```

`openshift-install create manifests` will validate the Azure environment
against ARM (virtual networks, regions, SKUs) before generating ignition,
so you need an Azure Service Principal **even for UPI**. See
`docs/azure-credentials.md` (added in a separate PR) for details.

## 5. Render Terraform vars

```bash
make tfvars         # writes from-env.auto.tfvars into every terraform/0X-* stack
```

This generates `from-env.auto.tfvars` per stack from `config/cluster.env`
plus the architecture-aware `architecture.auto.tfvars` and `vm-size.auto.tfvars`
files. Any hand-edited `terraform.tfvars` keys remain authoritative for
fields that are not in cluster.env.

## 6. Sanity check

```bash
make verify         # confirms openshift-install + oc + az + secrets are in place
```

## 7. One-command install

```bash
make all            # cost prompt > prereqs > network > image > bootstrap >
                    # control-plane > destroy-bootstrap > workers > install-complete
                    # (~60 min end-to-end, depending on region)
```

Pass `YES=1 make all` to skip the cost prompt. The chain is
re-runnable — every Terraform apply is idempotent — so you can Ctrl-C
and rerun if something needs attention. CSR approval is handled
automatically by the `wait-install` step (it backgrounds an approver
loop while waiting for the install-complete signal).

## 8. Multus secondary-NIC demo

```bash
source ./bin/env.sh                       # sets KUBECONFIG, PATH
oc apply -f manifests/multus/             # macvlan NAD + dualnic pod
oc -n multus-demo rollout status deploy/dualnic --timeout=5m
oc -n multus-demo exec deploy/dualnic -- ip -br a
```

## Day-2 helpers (all under ./bin/)

| Command | What it does |
|---|---|
| `./bin/status.sh` | Cluster + Azure VM power state summary |
| `./bin/park.sh` | Graceful shutdown + deallocate (~$30-50/mo while parked vs $500-800/mo running). Args passed through (`--no-backup`, `--yes`, etc.) |
| `./bin/start.sh` | Bring a parked cluster back online |
| `./bin/etcd-backup.sh` | Snapshot etcd to `backups/` |
| `./bin/teardown.sh` | `make destroy` everything the repo created |

Tab-completion (`./bin/<TAB>`) lists every wrapper.

## Where to go next

- `DEMO.md` — full step-by-step including the per-stage detail
- `OPERATIONS.md` — Day-2 lifecycle deep-dive
- `ARCHITECTURE.md` — cluster + network topology diagrams
- `CPU-ARCHITECTURE.md` — x86_64 vs arm64 host/cluster choices

If `make all` fails part-way through, rerun the failing target on its
own (e.g. `make bootstrap`) once the underlying problem is fixed. The
Terraform stacks each maintain their own state, so partial progress is
preserved.
