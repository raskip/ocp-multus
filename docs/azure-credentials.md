# Azure credentials for OpenShift UPI install

`openshift-install` reads Azure Service Principal credentials from a
single JSON file. This page covers the file format, permissions, and
cleanup. For *which* identity model to pick (single SP vs per-operator
SPs vs Workload Identity Federation), see
[`azure-identity-options.md`](./azure-identity-options.md).

## Permissions the person setting up the SP needs

Keep two identities separate:

1. **Provisioning operator** — the human or automation that creates the
   Entra application / Service Principal and grants Azure roles.
2. **Install Service Principal** — the identity saved in
   `~/.azure/osServicePrincipal.json` and used by `terraform`,
   `openshift-install`, and the cluster runtime.

The provisioning operator needs temporary setup rights; the install SP
gets the scoped runtime rights described in
[`azure-identity-options.md`](./azure-identity-options.md).

### 1. Create the Entra application / Service Principal

`az ad sp create-for-rbac --skip-assignment` creates an Entra
application, Service Principal, and client secret. It does **not** grant
Azure RBAC roles.

To run it, the provisioning operator needs one of:

| Tenant setting / role | When it is enough |
|---|---|
| Tenant allows users to register applications | Any normal member can create the app registration and SP. |
| **Application Developer** | Least-privilege Entra role when app registration is restricted. |
| **Cloud Application Administrator** / **Application Administrator** | Broader Entra roles that can also create and manage app registrations and secrets. |
| **Global Administrator** | Works, but should be a break-glass / PIM path, not the normal request. |

Many enterprise tenants use Privileged Identity Management (PIM). If so,
activate the directory role **before** running `az ad sp
create-for-rbac`.

### 2. Assign Azure RBAC roles to the install SP

`az role assignment create` requires the provisioning operator to hold a
role that includes `Microsoft.Authorization/roleAssignments/write` at
the scope being assigned. Common built-in choices:

| Role | Use |
|---|---|
| **User Access Administrator** | Least-privilege common role for role-assignment work only. |
| **Role Based Access Control Administrator** | Role-assignment administration without full Owner rights. |
| **Owner** | Full control, including role assignments. Use only if your governance model allows it. |
| Custom role with `Microsoft.Authorization/roleAssignments/write` | Use when your organisation has a custom least-privilege role. |

The scope matters. If DNS, networking, or private DNS live in different
subscriptions / resource groups, the owner of each scope must grant the
corresponding role:

| Target scope | Role granted to install SP | Who can grant it |
|---|---|---|
| Cluster subscription | Reader | Owner / User Access Administrator / Role Based Access Control Administrator at subscription scope. |
| Workload resource group | Contributor | Owner / User Access Administrator / Role Based Access Control Administrator on that RG or subscription. If the repo is expected to create the RG, the identity running `make prereqs` also needs permission to create resource groups at subscription scope, or the RG must be pre-created by the platform team. |
| VNet / network resource group | Network Contributor (or Contributor) | Owner / User Access Administrator / Role Based Access Control Administrator on the network RG or subscription. |
| Public DNS resource group that contains the parent zone and receives the child zone | DNS Zone Contributor | DNS/platform team. Required because the default Terraform path creates/tags the child public zone `${BASE_DOMAIN}` in this RG and writes the NS delegation into the parent zone. Parent-zone-only scope is not enough. |
| Private DNS zone `privatelink.blob.core.windows.net` or its RG | Private DNS Zone Contributor | Private-DNS / connectivity owner. |
| Installer storage account / workload RG | Storage Blob Data Owner for the install principal, or permission for Terraform to create that assignment | Owner / User Access Administrator / Role Based Access Control Administrator on the storage account, workload RG, or subscription. |

The provisioning operator does **not** need to stay privileged after the
roles are assigned. In PIM environments, activate the role, grant the
scoped assignments, run `make preflight`, and let the activation expire.

## File location and format

```
~/.azure/osServicePrincipal.json
```

```json
{
  "subscriptionId": "<sub-uuid>",
  "clientId":       "<sp-app-id-uuid>",
  "clientSecret":   "<sp-secret-value>",
  "tenantId":       "<tenant-uuid>"
}
```

Required keys: all four. Optional keys ignored by the installer.

## Required `chmod` and ownership

The file holds a long-lived secret. Set it to mode 600 and owned by
the user that runs `openshift-install`:

```bash
chmod 600 ~/.azure/osServicePrincipal.json
ls -l ~/.azure/osServicePrincipal.json
# -rw-------  1 you  you   220  ... osServicePrincipal.json
```

If the file is world-readable, openshift-install will warn (newer
versions) or proceed silently (older versions). Treat the warning as
fatal — secrets should never be readable by other users on a shared
jump host.

## Creating the file from `az ad sp create-for-rbac`

`az ad sp create-for-rbac` returns the secret **only once**. Capture
the output immediately:

```bash
SP_NAME="ocp-installer"

SP_JSON=$(az ad sp create-for-rbac \
  --name   "$SP_NAME" \
  --years  1 \
  --skip-assignment \
  -o json)

APP_ID=$(echo "$SP_JSON" | jq -r .appId)
SECRET=$(echo "$SP_JSON" | jq -r .password)
TENANT=$(echo "$SP_JSON" | jq -r .tenant)

mkdir -p ~/.azure
cat > ~/.azure/osServicePrincipal.json <<EOF
{
  "subscriptionId": "$SUBSCRIPTION_ID",
  "clientId":       "$APP_ID",
  "clientSecret":   "$SECRET",
  "tenantId":       "$TENANT"
}
EOF
chmod 600 ~/.azure/osServicePrincipal.json
```

Then assign roles (see `azure-identity-options.md` for the recommended
scopes per model).

## Verifying the credentials before install

A 3-second sanity check before `make prereqs`:

```bash
az login --service-principal \
  -u "$(jq -r .clientId     ~/.azure/osServicePrincipal.json)" \
  -p "$(jq -r .clientSecret ~/.azure/osServicePrincipal.json)" \
  --tenant "$(jq -r .tenantId ~/.azure/osServicePrincipal.json)" \
  -o none

az account show --query '{sub:id, tenant:tenantId, user:user.name}' -o table
```

If the SP login fails here, the install will also fail — fix the
credentials before continuing.

## Same file is reused by lifecycle scripts (post-install)

The day-2 scripts (`scripts/cluster-shutdown.sh`,
`scripts/cluster-startup.sh`, `scripts/cluster-etcd-backup.sh`) can
re-use the same credentials in non-interactive contexts (WSL2, CI).
The order of preference in `scripts/lib/common.sh` `require_az` is:

1. An already-active `az login` session.
2. Environment variables `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`,
   `AZURE_TENANT_ID` (preferred for CI).
3. The JSON file at `$AZURE_SP_JSON` or
   `~/.azure/osServicePrincipal.json` (uses `jq` to extract fields).

Example for an unattended cron job:

```bash
export AZURE_CLIENT_ID="$(jq -r .clientId     ~/.azure/osServicePrincipal.json)"
export AZURE_CLIENT_SECRET="$(jq -r .clientSecret ~/.azure/osServicePrincipal.json)"
export AZURE_TENANT_ID="$(jq -r .tenantId    ~/.azure/osServicePrincipal.json)"

make cluster-shutdown SHUTDOWN_FLAGS="--yes"
```

## Rotating the secret

```bash
APP_ID="$(jq -r .clientId ~/.azure/osServicePrincipal.json)"
NEW_SECRET=$(az ad sp credential reset --id "$APP_ID" \
  --query password -o tsv)

# Update the JSON file in-place
tmp=$(mktemp)
jq --arg s "$NEW_SECRET" '.clientSecret = $s' \
  ~/.azure/osServicePrincipal.json > "$tmp"
mv "$tmp" ~/.azure/osServicePrincipal.json
chmod 600 ~/.azure/osServicePrincipal.json
```

The cluster's `azure-cloud-credentials` secret in the
`openshift-cloud-controller-manager` namespace **also** has the secret
baked in — rotating the SP secret in Azure invalidates the in-cluster
copy. For Manual mode (E3) you'd update each operator's secret manifest;
for Mint mode (E2 default) you'd patch the cluster-cred-operator secret.

## Cleanup

After teardown:

```bash
APP_ID="$(jq -r .clientId ~/.azure/osServicePrincipal.json)"
az ad sp delete --id "$APP_ID"
rm -f ~/.azure/osServicePrincipal.json
```

Verify deletion:

```bash
az ad sp list --display-name "$SP_NAME" --query length
# Should print 0
```

## Common failure modes

| Symptom | Likely cause |
|---|---|
| `failed to get token: AADSTS7000215: Invalid client secret` | secret rotated in Azure but JSON not updated |
| `failed to load Azure credentials` from openshift-install | file missing or invalid JSON; run `jq . ~/.azure/osServicePrincipal.json` |
| `Authorization failed when attempting to perform action` during install | SP missing Contributor on workload RG (E2) — see `azure-identity-options.md` |
| `oc whoami` works but `az account show` fails in lifecycle scripts | non-interactive context with no `az login`; set `AZURE_CLIENT_ID/SECRET/TENANT_ID` env vars or rely on the JSON-file fallback in `scripts/lib/common.sh` |
