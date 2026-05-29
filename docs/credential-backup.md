# Credential backup bundles

OpenShift UPI creates several local secrets during install. Some are
generated only once, and losing them makes a later validation,
redeploy, or handover much harder. Run `make save-credentials` at each
major checkpoint and store the resulting bundle in an approved secret
location.

The bundle can contain cleartext secrets:

- Azure Service Principal JSON, including `clientSecret`.
- Red Hat pull secret.
- SSH private key.
- `install/auth/kubeconfig`.
- `install/auth/kubeadmin-password`.
- Terraform state and backups.
- Terraform outputs, including the optional Windows jump-host password
  when `CREATE_WINDOWS_JUMP=true`.

Do **not** commit, publish, email, or attach the bundle to tickets.

## Save a bundle

Default usage:

```bash
make save-credentials
```

With no arguments, the script writes to a timestamped directory:

```text
secrets/cluster-auth/<UTC timestamp>-<cluster-name>/
```

`secrets/*` is ignored by git in this repository, so the default path is
safe from accidental commits. If you choose a custom path inside the
repository, the script refuses to continue unless that exact path is
ignored by git.

Use a specific destination when you want a stable run folder:

```bash
make save-credentials CREDENTIALS_DIR=secrets/cluster-auth/lab-20260529
```

`CREDENTIALS_DIR` is always the final output directory. Existing
non-empty directories are refused unless you intentionally pass
`--force`:

```bash
make save-credentials \
  CREDENTIALS_DIR=secrets/cluster-auth/lab-20260529 \
  CREDENTIALS_FLAGS=--force
```

The script prints only paths and status. It does not print secret values
to stdout or stderr. Inspect `inventory.txt` inside the bundle for the
saved/missing artefact list.

## When to run it

Run it more than once. Each checkpoint captures a different set of
files:

| Checkpoint | Why |
|---|---|
| Before cleanup / redeploy | Preserve the config, SP JSON, SSH key, pull secret, and any remaining Terraform state. |
| After `make ignition` | `install/auth/kubeconfig`, `install/auth/kubeadmin-password`, installer metadata, and ignition state now exist. |
| After `make network` | Terraform network outputs now exist, including optional Windows jump-host credentials. |
| After `make wait-install` or `make all` | Final cluster access files and Terraform states are known-good. |
| After any manual Bastion, DNS, role, or access fix | Keep the run bundle aligned with the actual environment. |

## What is captured

The current implementation is local-only; it does not require an Azure
login and does not query Azure. It copies artefacts that exist on disk:

- `config/cluster.env`
- `secrets/pull-secret.txt`
- `secrets/id_ed25519` and `secrets/id_ed25519.pub`
- `$AZURE_SP_JSON` when explicitly provided; otherwise
  `$AZURE_CONFIG_DIR/osServicePrincipal.json` when `AZURE_CONFIG_DIR` is
  set; otherwise `~/.azure/osServicePrincipal.json`
- `install-config/install-config.yaml`
- the `install/` directory, including `install/auth/`
- root-level OpenShift installer logs/state when present
- Terraform `*.tfvars`, local state, state backups, lock files, and
  best-effort `terraform output -json` per stack

Because Terraform output JSON includes sensitive values in cleartext,
the output files are intentionally part of the secret bundle.

If you use separate Azure CLI profiles, set `AZURE_CONFIG_DIR` before
running the save target so the bundle captures the intended Service
Principal JSON and never falls back to a different default profile:

```bash
export AZURE_CONFIG_DIR="$HOME/.azure-my-ocp-lab"
make save-credentials
```

## Restore / handover use

Use the bundle as a reference and copy files back deliberately; do not
blindly overlay an old bundle onto a new run.

Common restore examples:

```bash
cp <bundle>/config/cluster.env config/cluster.env
cp <bundle>/azure/osServicePrincipal.json "$AZURE_CONFIG_DIR/osServicePrincipal.json"
cp <bundle>/secrets/id_ed25519 secrets/id_ed25519
cp <bundle>/secrets/id_ed25519.pub secrets/id_ed25519.pub
cp <bundle>/secrets/pull-secret.txt secrets/pull-secret.txt
cp -a <bundle>/install install
```

After restoring, run:

```bash
make verify
make preflight
```
