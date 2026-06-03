# Contributing

Thanks for your interest in improving **ocp-multus**. This repo is a generic,
public runbook + Terraform/Bash template for OpenShift-on-Azure (UPI) with
optional Multus secondary networking. Contributions that keep it generic,
safe, and easy for a first-time operator are very welcome.

## Ground rules

1. **Never commit secrets or tenant identifiers.** No credentials, kubeconfigs,
   pull secrets, private keys, Terraform state, subscription/tenant IDs,
   internal IPs, resource-group/VNet names, UPNs, or emails. Anything
   environment-specific stays local.
2. **Keep it generic.** Use placeholders (`example.com`,
   `00000000-0000-0000-0000-000000000000`, `REDACTED_RESOURCE_GROUPwork`) in docs and
   `*.tfvars.example`. Real values belong only in your local, gitignored
   `config/cluster.env` / `*.auto.tfvars` / `secrets/`.
3. **Docs are part of the change.** Update the relevant runbook in `docs/` when
   you change behavior.

## Before you push

Run the same checks CI runs:

```bash
# 1. Leak guard — set up your own local patterns once:
cp .sanitize-patterns.example .sanitize-patterns.local   # gitignored
$EDITOR .sanitize-patterns.local                         # add YOUR identifiers
bash scripts/sanitize-check.sh

# 2. Shell lint + syntax
shellcheck $(git ls-files '*.sh')
bash -n $(git ls-files '*.sh')

# 3. Terraform formatting + validation
terraform fmt -check -recursive
for d in terraform/*/; do
  terraform -chdir="$d" init -backend=false -input=false
  terraform -chdir="$d" validate
done
```

Optionally install the pre-push hook so the leak guard runs automatically:

```bash
make install-hooks
```

## Pull requests

- Keep PRs focused and describe the operator-facing impact.
- Make sure CI is green (`sanitize-check`, `shellcheck`, `bash -n`,
  `terraform fmt`/`validate`, secret scan).
- By contributing you agree your work is released under the repo's
  [MIT License](./LICENSE).

## Reporting security issues

See [`SECURITY.md`](./SECURITY.md). Do not open public issues for anything that
could expose secrets.
