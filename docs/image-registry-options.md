# Image-registry storage options for restricted Azure tenants

The OpenShift image-registry operator defaults to "managed" on Azure:
it creates a storage account in the cluster resource group and uses
shared-key auth to read/write blobs. Many enterprise tenants disable
shared-key auth at the storage-account or subscription level
(e.g. `allowSharedKeyAccess=false` enforced by policy), which leaves
the operator in `Available=False, Degraded=True` after install.

This page covers the three working patterns. The repo's default PoC
flow sets the operator to **Removed** during `make wait-install` so a
restricted storage policy does not block first install. Choose a final
option as Day-2 work, or opt out and configure managed registry storage
before install.

```bash
# Default: AUTO_IMAGE_REGISTRY_REMOVED=true
make wait-install

# Opt out when you have configured managed registry storage yourself
AUTO_IMAGE_REGISTRY_REMOVED=false make wait-install
```

## Symptoms when the default flow is blocked

```bash
oc get co image-registry
# NAME            VERSION   AVAILABLE   PROGRESSING   DEGRADED
# image-registry  4.18.x    False       True          True

oc -n openshift-image-registry logs deploy/cluster-image-registry-operator | tail -50
# Common errors:
#   "shared key auth is not allowed by tenant policy"
#   "AccountConfigurationDisabled"
#   "StorageAccountIsNotAuthorized"
```

A degraded image-registry blocks `openshift-install wait-for install-complete`
from going Available. The default wait-install helper applies Option A
below automatically for PoC success; pick another option when you need
the in-cluster registry.

## Option A — Removed (simplest, smallest blast radius)

Mark the image registry as `Removed`. The operator stops trying to
create storage, the cluster operator reports `Available=True`, and the
install completes. Workloads that need an in-cluster registry (image
builds via `oc new-build`, ImageStream pulls) won't work — that's the
trade-off.

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge \
  -p '{"spec":{"managementState":"Removed"}}'
```

Verification:

```bash
oc get co image-registry
# NAME            VERSION   AVAILABLE   PROGRESSING   DEGRADED
# image-registry  4.18.x    True        False         False
```

This repo provides a convenience target:

```bash
make image-registry-removed
```

The target is idempotent and safe to re-run.

## Option B — Managed with AAD (managed-identity) auth

Keep the image registry managed but tell it to authenticate to the
storage account via Azure AD (workload identity / managed identity)
instead of shared-key. Requires:

- A storage account with `allowSharedKeyAccess=false` (the registry will
  create one with this setting if not pre-created).
- A managed identity (UAMI) or workload identity bound to the
  `image-registry` service account with **Storage Blob Data
  Contributor** on the account.

```yaml
# patch.yaml
spec:
  managementState: Managed
  storage:
    azure:
      accountName: ""              # let operator generate
      cloudName: AzurePublicCloud
      networkAccess:
        type: External
  # If using Manual cloud-credentials, point the registry to a
  # workload-identity secret created via ccoctl:
  # credentialsMode: Manual (set in cluster-config)
```

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge --patch-file=patch.yaml
```

After patching, watch `oc get co image-registry` and the operator logs
until it transitions to `Available=True`.

**Notes:**
- This option assumes the cluster uses Manual cloud-credential mode
  (option E3 in [`azure-identity-options.md`](./azure-identity-options.md))
  or Workload Identity Federation (E4).
- For Mint mode (E2), shared-key auth is the implicit assumption — if
  shared-key is blocked, you must migrate to E3/E4 first.

## Option C — Pre-created storage account + identity-based auth

Create the storage account out-of-band (e.g. by the platform team), set
its policy explicitly, and point the image-registry operator at it.

```bash
# Platform-team step (or Terraform)
STORAGE_ACCT="ocpregistry$(openssl rand -hex 4)"

az storage account create \
  --name "$STORAGE_ACCT" \
  --resource-group "$WORKLOAD_RG" \
  --location "$REGION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-shared-key-access false \
  --default-action Deny \
  --bypass AzureServices \
  --min-tls-version TLS1_2

az storage container create \
  --account-name "$STORAGE_ACCT" \
  --name "openshift-image-registry" \
  --auth-mode login

# Grant the registry's managed identity Storage Blob Data Contributor
az role assignment create \
  --assignee "$REGISTRY_MI_PRINCIPAL_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$WORKLOAD_RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCT"
```

Then point the operator:

```yaml
# patch.yaml
spec:
  managementState: Managed
  storage:
    azure:
      accountName: "${STORAGE_ACCT}"
      container:   "openshift-image-registry"
      cloudName:   AzurePublicCloud
```

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge --patch-file=patch.yaml
```

This is the most controlled option — the platform team owns the
account, all access is audited via AAD, and the registry never holds a
storage key. It's also the most setup work (storage account + RBAC +
patch + verify).

## Decision matrix

| Option | When to use | Lasts | Effort |
|---|---|---|---|
| A — Removed | PoC / lab / no in-cluster builds needed | minutes | tiny |
| B — Managed with AAD auth | Production, customer accepts operator-created storage | day-2 | medium |
| C — Pre-created + AAD | Production, platform team owns all storage accounts | one-time platform work | high |

## Validation after any option

```bash
oc wait --for=condition=Available co/image-registry --timeout=10m

oc get pods -n openshift-image-registry
# Should show image-registry-*  Running

oc get route -n openshift-image-registry
# Should show default-route (after the registry has exposed a route)

# Smoke test: push and pull a tiny image
oc new-project img-smoke
oc run hello --image=quay.io/openshift/origin-hello-openshift:latest
oc -n img-smoke wait --for=condition=Ready pod/hello --timeout=2m
oc delete project img-smoke
```

If `oc get co image-registry` still shows `Degraded=True` after 10
minutes, check the operator logs (`oc -n openshift-image-registry logs
deploy/cluster-image-registry-operator`) for the specific Azure auth
error.

## CNF / telco profile note

The optional CNF profile (see [`cnf-telco-profile.md`](./cnf-telco-profile.md))
**requires** an in-cluster registry for internal ImageStreams, so it does **not**
use Option A. Instead:

1. Install with `AUTO_IMAGE_REGISTRY_REMOVED=false` (set in
   `config/cluster.cnf.example.env`) so `wait-install` leaves the registry alone.
2. Run `scripts/configure-image-registry-managed.sh` to apply Option B (or set
   `ACCOUNT_NAME`/`CONTAINER_NAME` for the Option C pre-created account). The
   `make cnf-apply` sequence runs this as its final step.

If an external registry (Quay / ACR) is acceptable to the CNF vendor, that is
simpler than running the in-cluster registry — confirm during the workshop.

## Related

- [`azure-identity-options.md`](./azure-identity-options.md) —
  CCO mode (Mint / Manual / WIF) affects which option fits.
- [`required-outbound-destinations.md`](./required-outbound-destinations.md) —
  if the storage account uses Private Endpoint, ensure
  `*.blob.core.windows.net` resolves via the cluster's private DNS zone.
- Upstream: *OpenShift documentation → Image Registry → Configuring
  registry storage for Azure*.
