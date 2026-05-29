# Quickstart — UPI veteran flow

If you have done OpenShift UPI on Azure before and just want the
commands, this is the page. For the full guided playbook with
decisions, prerequisites, and post-install context see
[`onboarding.md`](./onboarding.md). For per-`make`-target detail and
debugging see [`manual-install.md`](./manual-install.md).

Assumes a WSL2 / Linux / macOS shell with `bash` ≥ 4, `make`, `jq`,
`az` (Azure CLI), and `terraform` ≥ 1.6 already on `PATH`, plus an
Azure subscription where you can create resources. Run `make verify`
once after cloning — it auto-checks all of these and points to
install hints if anything is missing.

> Also assumes the pre-install procurement work is already done (Red
> Hat pull secret in hand, Azure SP + roles, DNS delegation, vCPU
> quota, firewall outbound allowlist, and proxy/TLS-inspection decision).
> If not, start at
> [`pre-install-checklist.md`](./pre-install-checklist.md).

## 1. Clone + tools

```bash
git clone https://github.com/raskip/ocp-multus.git
cd ocp-multus
make tools                     # downloads matching openshift-install + oc
```

## 2. Secrets

The Red Hat pull secret is architecture-neutral — download from
<https://console.redhat.com/openshift/install/pull-secret>.

```bash
mkdir -p secrets
cp /path/to/pull-secret.txt secrets/pull-secret.txt
ssh-keygen -t ed25519 -f secrets/id_ed25519 -N ''
```

## 3. Config (interactive wizard)

```bash
make init-config               # ~12 prompts with sensible defaults
                               # writes config/cluster.env
                               # rerun with FORCE=1 to overwrite
```

`config/cluster.env` is the single source of truth that feeds every
Terraform stack and shell script via
`scripts/render-tfvars-from-env.sh`.

## 4. Azure auth

```bash
./bin/login.sh                 # env-var SP > ~/.azure/osServicePrincipal.json > device code
```

Even on UPI you need an Azure Service Principal because
`openshift-install create manifests` validates against ARM. See
[`azure-credentials.md`](./azure-credentials.md) and
[`azure-identity-options.md`](./azure-identity-options.md) for the
five identity patterns (E1–E5).

## 5. Render Terraform vars + sanity check

```bash
make tfvars                    # writes from-env.auto.tfvars into every stack
make verify                    # confirms binaries + secrets in place
```

## 6. Preflight + install

```bash
make preflight                 # Azure RBAC, quotas, network reach, DNS
make all                       # full install end-to-end (~60 min)
                               # cost prompt > prereqs > network > image >
                               # bootstrap > control-plane > destroy-bootstrap >
                               # workers > install-complete
                               # YES=1 make all  → skip the cost prompt
make save-credentials          # capture kubeconfig/passwords/state/outputs
```

If your enterprise firewall/proxy terminates TLS, stop here and read
[`proxy-and-tls-inspection.md`](./proxy-and-tls-inspection.md) before
`make all`. The current automation does **not** yet inject proxy or
`additionalTrustBundle` settings from `config/cluster.env`; treating
this as "just an outbound allowlist" can strand bootstrap on `x509`
image-pull errors.

The chain is re-runnable after transient failures. Terraform applies
are idempotent, and `make ignition` reuses existing `install/*.ign`
assets once `install/metadata.json` exists so reruns do not rotate the
cluster infraID or delete `install/auth/`. To intentionally rebuild the
installer state, run `make clean-install` first (or use `FORCE=1 make
ignition`). CSR approval is handled automatically by the `wait-install`
step.

`make all` does **not** require the optional Windows browser/RDP jump
host. Set `CREATE_WINDOWS_JUMP=true` in `config/cluster.env` only if
you explicitly want that convenience host for accessing an internal
OpenShift console; otherwise use your chosen jump-host access pattern
from [`jump-host-access-decision.md`](./jump-host-access-decision.md).

Run [`make save-credentials`](./credential-backup.md) after major
checkpoints, especially after `make ignition`, after `make network`, and
after the install completes. It saves local cluster credentials,
Terraform state, SP JSON, and optional Windows jump-host credentials into
a gitignored bundle so they are not lost during cleanup or handover.

## 7. (Optional) Multus secondary-network demo

```bash
source ./bin/env.sh                       # sets KUBECONFIG + PATH
oc apply -f manifests/multus/             # macvlan NAD + dualnic pod
oc -n multus-demo rollout status deploy/dualnic --timeout=5m
oc -n multus-demo exec deploy/dualnic -- ip -br a
```

See [`multus-validation.md`](./multus-validation.md) for the full
walk-through (NIC-name confirmation, Whereabouts IPAM, host-device /
SR-IOV demo, arm64 gotchas, cleanup).

## Day-2 helpers

| Command | What it does |
|---|---|
| `./bin/status.sh` | Cluster + Azure VM power state summary |
| `./bin/park.sh` | Graceful shutdown + deallocate (~$30-50/mo while parked vs $500-800/mo running). Args passed through (`--no-backup`, `--yes`, etc.) |
| `./bin/start.sh` | Bring a parked cluster back online |
| `./bin/etcd-backup.sh` | Snapshot etcd to `backups/` |
| `./bin/teardown.sh` | `make destroy` everything the repo created |

Tab-completion (`./bin/<TAB>`) lists every wrapper. See
[`operations.md`](./operations.md) for the full Day-2 runbook.

## If something breaks

Re-run the failing target on its own (e.g. `make bootstrap`) once the
underlying problem is fixed. Each Terraform stack has its own state,
so partial progress is preserved. Read
[`preflight-checklist.md`](./preflight-checklist.md) for the most
common failures and their fixes.
