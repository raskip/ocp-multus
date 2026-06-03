# Azure-native automation for OCP lifecycle scripts

> **TL;DR**
>
> If you cannot or don't want to use GitHub Actions or on-host cron
> (`scheduling.md`), the recommended Azure-native path is **Azure
> Container Apps Jobs** triggered on a schedule. A solid alternative
> for orgs with an existing Azure Automation control plane is **Azure
> Automation + Linux Hybrid Worker**. This document covers both in
> depth, and gives an honest "at a glance" view of Azure Functions and
> Azure DevOps Pipelines plus a short list of things you should *not*
> reach for.

This document is a companion to:

- [`operations.md`](./operations.md) — what each script does.
- [`scheduling.md`](./scheduling.md) — GitHub Actions, host cron, and
  systemd patterns.
- [`docs/scripts/`](./scripts/README.md) — per-script CLI reference.

---

## Why this is its own document

The lifecycle scripts have four constraints that filter Azure
schedulers more aggressively than a generic "run something nightly"
task:

1. **They run bash** and call `oc` and `az`. PowerShell-only or
   .NET-only runtimes need extra plumbing.
2. **They can run for a long time.** A `cluster-startup` may sit in
   `wait_for_cluster_operators` for the full `OPERATIONS_TIMEOUT_MIN`
   (script default is 30 min; the examples in this doc raise it to
   45 min for scheduled use to leave headroom) plus earlier waits —
   call it 60 min worst case.
3. **They need two credentials.** Azure (for `az vm start/deallocate`)
   AND OCP (kubeconfig or a long-lived `ServiceAccount` token).
4. **They must fail loudly.** `cluster-startup.sh` exits non-zero on
   degraded health; that exit code has to surface to whatever
   alerting layer your team uses.

The shortlist that survives these filters:

- ✅ Azure Container Apps Jobs (scheduled trigger)
- ✅ Azure Automation + Linux Hybrid Worker (bash runbook)
- ⚠️ Azure Functions (Premium, Linux container, timer trigger) — works
  with care, see "At a glance" below
- ⚠️ Azure DevOps Pipelines (scheduled) — works, see "At a glance" below

Everything else is in "Don't use these" further down.

---

## Decision matrix

| Axis | Container Apps Jobs | Automation + Hybrid Worker | Functions (Premium) | ADO Pipelines |
|---|---|---|---|---|
| Setup complexity | Low–medium (container image + 1 ACA env + 2 jobs) | Medium (Automation account + worker VM + runbook) | Medium (Premium plan + container image + bindings) | Low (YAML pipeline; same as GHA) |
| Where compute lives | Fully managed by Azure | You own a worker VM (or Arc-enabled server) | Fully managed by Azure | Microsoft-hosted Linux agent |
| Cost shape | Pay per second of execution + a tiny env idle cost | Worker VM cost (24/7) + ~free Automation jobs | Premium plan minimum + execution | Free tier or per-minute |
| Long-wait friendliness | ✅ `replicaTimeout` configurable to many hours | ✅ Not subject to the Azure sandbox 3h fair-share limit on a Hybrid Worker | ⚠️ Function timeout default 30 min on Premium; raise carefully | ✅ Job timeout 60 min default on hosted agents, raisable to 360 min |
| Auth fit (Azure) | ✅ user-assigned MI on the env / job | ✅ system-assigned MI on the worker VM | ✅ MI on the function app | ✅ Workload identity federation (OIDC) |
| Auth fit (OCP) | KUBECONFIG via ACA secret or Key Vault ref | KUBECONFIG fetched from Key Vault by the runbook (worker MI → KV) | KUBECONFIG via app setting or Key Vault | KUBECONFIG via pipeline secret variable |
| Native logs | Container Apps logs + Log Analytics | Job streams + Log Analytics | App Insights + Log Analytics | Pipeline run logs |
| Discoverability for ops team | Container Apps blade | Automation Runbooks blade | Function App blade | Pipelines blade |
| Honest fit verdict | ✅ Recommended default | ✅ Good fit if Automation is already the org's standard | ⚠️ Use when function timeout is comfortably > 60 min | ✅ Recommended for ADO-first orgs |

### Decision flow

- **No existing Azure ops tooling, want the cleanest result** →
  Container Apps Jobs.
- **Org already runs everything through Azure Automation runbooks** →
  Automation + Hybrid Worker.
- **Org already runs everything through Azure DevOps** → ADO
  Pipelines (mirror the GHA pattern in `scheduling.md`).
- **Need to chain into a wider Logic Apps / event-driven workflow** →
  Container Apps Job invoked over its REST start endpoint, fronted
  by whatever orchestrator you already have.

---

## Option 1: Azure Container Apps Jobs (recommended default)

A Container Apps Job is a short-lived workload that runs in an
Azure-managed serverless container, on a cron schedule. It's the
closest Azure-native analog to "GitHub Actions, but inside Azure" and
fits the lifecycle scripts very well: a container, a schedule, a
managed identity, and integrated log streaming.

### Why it's a good fit

- `replicaTimeout` can be set in the multi-hour range. Microsoft has
  no documented hard cap, and multi-hour replica timeouts are
  routinely run in production — comfortably above our worst-case
  startup wait.
- You bring your own image, so the same container that runs in CI
  can run on the schedule. No drift between dev and prod tooling.
- Managed identity is first-class: bind a user-assigned identity to
  the job, then `az login --identity` inside the container.
- Logs stream live to the Container Apps blade and persist in the
  Log Analytics workspace attached to the Container Apps environment.

### Container image (Dockerfile)

```dockerfile
# Dockerfile — build with: docker build -t <acr>.azurecr.io/ocp-multus-lifecycle:1 .
FROM mcr.microsoft.com/azure-cli:latest

# Install make, jq, curl, and oc (OpenShift client) on top of the official az image.
RUN tdnf install -y make jq tar gzip ca-certificates curl && \
    curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        -o /tmp/oc.tar.gz && \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl && \
    rm -f /tmp/oc.tar.gz

# Copy the lifecycle scripts into the image.
WORKDIR /opt/ocp-multus
COPY Makefile ./
COPY scripts/ ./scripts/
COPY config/ ./config/

# The job entrypoint is whatever the schedule passes as a command,
# e.g. ["make","cluster-shutdown"] or ["make","cluster-startup"].
ENTRYPOINT ["/bin/bash","-l","-c"]
```

Build and push:

```bash
ACR=myorgacr
az acr build --registry "$ACR" -t ocp-multus-lifecycle:1 .
```

> **On image hosting**: Azure Container Registry is the natural
> choice (private, MI-friendly, regional). A public image on GitHub
> Container Registry works too, but treat your image as a supply
> chain artifact — pin a digest, not a moving tag.

### Container Apps environment

One Container Apps environment hosts both the shutdown and startup
jobs. It does not need to be the same environment as your application
workloads:

```bash
RG=rg-ocp-lifecycle
LOC=eastus
ENV=cae-ocp-lifecycle
LA=la-ocp-lifecycle
UA_MI=mi-ocp-lifecycle

az group create -n "$RG" -l "$LOC"

# Log Analytics workspace (logs target)
LA_ID=$(az monitor log-analytics workspace create \
    -g "$RG" -n "$LA" --query id -o tsv)
LA_CKEY=$(az monitor log-analytics workspace get-shared-keys \
    -g "$RG" -n "$LA" --query primarySharedKey -o tsv)
LA_CID=$(az monitor log-analytics workspace show \
    -g "$RG" -n "$LA" --query customerId -o tsv)

# User-assigned MI used by both jobs
UA_ID=$(az identity create -g "$RG" -n "$UA_MI" --query id -o tsv)
UA_PRINCIPAL=$(az identity show -g "$RG" -n "$UA_MI" \
    --query principalId -o tsv)
UA_CLIENT_ID=$(az identity show -g "$RG" -n "$UA_MI" \
    --query clientId -o tsv)

# Container Apps environment with the Log Analytics workspace bound
az containerapp env create -g "$RG" -n "$ENV" -l "$LOC" \
    --logs-workspace-id "$LA_CID" \
    --logs-workspace-key "$LA_CKEY"
```

Grant the MI the rights it actually needs (workload RG only):

```bash
WORKLOAD_RG=rg-ocp-lab
SUB=$(az account show --query id -o tsv)

# Power-cycle VMs in the workload RG
az role assignment create \
    --assignee-object-id "$UA_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/$SUB/resourceGroups/$WORKLOAD_RG"

# Optional: pull from your ACR
ACR_ID=$(az acr show -n myorgacr --query id -o tsv)
az role assignment create \
    --assignee-object-id "$UA_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "AcrPull" --scope "$ACR_ID"
```

### Path A — Managed Identity (recommended)

The MI authenticates to Azure (for `az vm`) but **not** to OpenShift.
The OCP kubeconfig is still a secret you have to give the job. The
recommended path is to keep the kubeconfig in Azure Key Vault and let
the job read it through a Key Vault secret reference, so the secret
material never lives in an ACA configuration export.

```bash
KV=kv-ocp-lifecycle
az keyvault create -g "$RG" -n "$KV" -l "$LOC" \
    --enable-rbac-authorization true

# Grant the MI read access to KV secrets
az role assignment create \
    --assignee-object-id "$UA_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "$(az keyvault show -n $KV --query id -o tsv)"

# Stash the kubeconfig (base64-encoded so it survives env vars cleanly)
base64 -w0 ~/.kube/config | az keyvault secret set \
    --vault-name "$KV" --name ocp-kubeconfig-b64 --file /dev/stdin

# Resolve the version-less secret URI we'll feed to the job
KUBECONFIG_KV_URI=$(az keyvault secret show \
    --vault-name "$KV" --name ocp-kubeconfig-b64 \
    --query id -o tsv | sed 's|/[^/]*$||')
```

Create the shutdown job:

```bash
az containerapp job create \
    -g "$RG" -n ocp-cluster-shutdown \
    --environment "$ENV" \
    --image "$ACR.azurecr.io/ocp-multus-lifecycle:1" \
    --trigger-type Schedule \
    --cron-expression "0 18 * * 1-5" \
    --replica-timeout 7200 \
    --replica-retry-limit 0 \
    --parallelism 1 \
    --replica-completion-count 1 \
    --mi-user-assigned "$UA_ID" \
    --registry-server "$ACR.azurecr.io" \
    --registry-identity "$UA_ID" \
    --secrets ocp-kubeconfig-b64=keyvaultref:$KUBECONFIG_KV_URI,identityref:$UA_ID \
    --env-vars \
        AZURE_CLIENT_ID=$UA_CLIENT_ID \
        KUBECONFIG_B64=secretref:ocp-kubeconfig-b64 \
        CLUSTER_NAME=lab \
        WORKLOAD_RESOURCE_GROUP=$WORKLOAD_RG \
        CLUSTER_SUBSCRIPTION_ID=$SUB \
        CONTROL_PLANE_VM_PREFIX=vm-master- \
        WORKER_VM_PREFIX=vm-worker- \
        SRIOV_WORKER_VM_NAME=vm-worker-sriov-lab \
        ASSUME_YES=1 \
        OPERATIONS_TIMEOUT_MIN=45 \
    --command "/bin/bash" \
    --args "-lc" "
        set -euo pipefail
        # Materialize KUBECONFIG from the secret
        mkdir -p /root/.kube
        printf '%s' \"\$KUBECONFIG_B64\" | base64 -d > /root/.kube/config
        chmod 600 /root/.kube/config
        export KUBECONFIG=/root/.kube/config
        # Authenticate to Azure via the bound managed identity
        az login --identity --client-id \"\$AZURE_CLIENT_ID\"
        az account set --subscription \"\$CLUSTER_SUBSCRIPTION_ID\"
        # Write the cluster.env file the scripts expect
        cat > /opt/ocp-multus/config/cluster.env <<EOF
CLUSTER_NAME=\$CLUSTER_NAME
WORKLOAD_RESOURCE_GROUP=\$WORKLOAD_RESOURCE_GROUP
CLUSTER_SUBSCRIPTION_ID=\$CLUSTER_SUBSCRIPTION_ID
CONTROL_PLANE_VM_PREFIX=\$CONTROL_PLANE_VM_PREFIX
WORKER_VM_PREFIX=\$WORKER_VM_PREFIX
SRIOV_WORKER_VM_NAME=\$SRIOV_WORKER_VM_NAME
EOF
        cd /opt/ocp-multus
        make cluster-shutdown
    "
```

> `--mi-user-assigned` binds the identity. The job explicitly sets
> `AZURE_CLIENT_ID` from the user-assigned identity's client ID
> (resolved above) so `az login --identity --client-id "$AZURE_CLIENT_ID"`
> selects the intended identity even when more than one MI is attached.
> The Container Apps runtime exposes `IDENTITY_ENDPOINT` and
> `IDENTITY_HEADER` for the IMDS sidecar, but **not** `AZURE_CLIENT_ID` —
> that's why we pass it explicitly.

Create the startup job (same shape, different command + schedule):

```bash
az containerapp job create \
    -g "$RG" -n ocp-cluster-startup \
    --environment "$ENV" \
    --image "$ACR.azurecr.io/ocp-multus-lifecycle:1" \
    --trigger-type Schedule \
    --cron-expression "0 6 * * 1-5" \
    --replica-timeout 7200 \
    --replica-retry-limit 0 \
    --parallelism 1 \
    --replica-completion-count 1 \
    --mi-user-assigned "$UA_ID" \
    --registry-server "$ACR.azurecr.io" \
    --registry-identity "$UA_ID" \
    --secrets ocp-kubeconfig-b64=keyvaultref:$KUBECONFIG_KV_URI,identityref:$UA_ID \
    --env-vars \
        AZURE_CLIENT_ID=$UA_CLIENT_ID \
        KUBECONFIG_B64=secretref:ocp-kubeconfig-b64 \
        CLUSTER_NAME=lab \
        WORKLOAD_RESOURCE_GROUP=$WORKLOAD_RG \
        CLUSTER_SUBSCRIPTION_ID=$SUB \
        CONTROL_PLANE_VM_PREFIX=vm-master- \
        WORKER_VM_PREFIX=vm-worker- \
        SRIOV_WORKER_VM_NAME=vm-worker-sriov-lab \
        OPERATIONS_TIMEOUT_MIN=45 \
    --command "/bin/bash" \
    --args "-lc" "
        set -euo pipefail
        mkdir -p /root/.kube
        printf '%s' \"\$KUBECONFIG_B64\" | base64 -d > /root/.kube/config
        chmod 600 /root/.kube/config
        export KUBECONFIG=/root/.kube/config
        az login --identity --client-id \"\$AZURE_CLIENT_ID\"
        az account set --subscription \"\$CLUSTER_SUBSCRIPTION_ID\"
        cat > /opt/ocp-multus/config/cluster.env <<EOF
CLUSTER_NAME=\$CLUSTER_NAME
WORKLOAD_RESOURCE_GROUP=\$WORKLOAD_RESOURCE_GROUP
CLUSTER_SUBSCRIPTION_ID=\$CLUSTER_SUBSCRIPTION_ID
CONTROL_PLANE_VM_PREFIX=\$CONTROL_PLANE_VM_PREFIX
WORKER_VM_PREFIX=\$WORKER_VM_PREFIX
SRIOV_WORKER_VM_NAME=\$SRIOV_WORKER_VM_NAME
EOF
        cd /opt/ocp-multus
        make cluster-startup
    "
```

> **Why `--replica-retry-limit 0`?** A failed startup retry would
> probably hit the same root cause. Better to fail loudly once and
> let the on-call investigate, which is exactly what
> `cluster-startup.sh`'s fail-fast behavior is designed for.

### Path B — Service Principal (alternative)

If your governance disallows managed identities, or you want a
secret-only path so the same image can run anywhere (CI, host cron,
ACA), authenticate to Azure with a service principal stored in the
same Key Vault:

```bash
# One-time: create the SP scoped to the workload RG
SP_JSON=$(az ad sp create-for-rbac \
    --name "sp-ocp-multus-lifecycle" \
    --role "Virtual Machine Contributor" \
    --scopes "/subscriptions/$SUB/resourceGroups/$WORKLOAD_RG" \
    --json-auth)
APP_ID=$(jq -r '.clientId' <<<"$SP_JSON")
APP_SECRET=$(jq -r '.clientSecret' <<<"$SP_JSON")
APP_TENANT=$(jq -r '.tenantId' <<<"$SP_JSON")

# Stash the credential
printf '%s' "$APP_SECRET" | az keyvault secret set \
    --vault-name "$KV" --name ocp-sp-password --file /dev/stdin

# Resolve the version-less secret URI we'll feed to the job
SPPASS_KV_URI=$(az keyvault secret show \
    --vault-name "$KV" --name ocp-sp-password \
    --query id -o tsv | sed 's|/[^/]*$||')
```

Replace the `az login --identity ...` line in the job command with:

```bash
az login --service-principal \
    -u "$ARM_CLIENT_ID" \
    -p "$ARM_CLIENT_SECRET" \
    --tenant "$ARM_TENANT_ID"
```

And add three more secrets/env vars to the job:

```bash
--secrets \
    ocp-kubeconfig-b64=keyvaultref:$KUBECONFIG_KV_URI,identityref:$UA_ID \
    sp-client-secret=keyvaultref:$SPPASS_KV_URI,identityref:$UA_ID \
--env-vars \
    ...
    ARM_CLIENT_ID=$APP_ID \
    ARM_TENANT_ID=$APP_TENANT \
    ARM_CLIENT_SECRET=secretref:sp-client-secret \
```

The KV-read MI binding is still useful with SP mode — it's what lets
the secret references resolve at job start.

### Etcd backups

Container Apps Jobs run on an ephemeral filesystem. Any etcd backup
the shutdown script writes under `backups/` disappears when the
replica exits. For a real backup discipline, push the backup
directory to Blob Storage as the last step of the shutdown command:

```bash
az storage blob upload-batch \
    --account-name stocpbackups \
    --auth-mode login \
    --destination "ocp-backups/$CLUSTER_NAME" \
    --source backups/
```

Grant the MI `Storage Blob Data Contributor` on the storage account
ahead of time, and add a Blob lifecycle management rule to expire or
tier old backups (e.g., 30 days hot → cool → delete at 180 days).

### Logging and monitoring

- Live tail: `az containerapp job logs show -n ocp-cluster-shutdown -g $RG`
- Persistent: query the bound Log Analytics workspace:
  ```kusto
  ContainerAppConsoleLogs_CL
  | where ContainerJobName_s in ("ocp-cluster-shutdown","ocp-cluster-startup")
  | order by TimeGenerated desc
  ```
- Alerting: a `ContainerAppSystemLogs_CL` query for jobs with
  `ExecutionStatus_s != "Succeeded"` is enough to wire a Log Analytics
  alert that pages on-call when a scheduled run fails.

### Concurrency

ACA Jobs do **not** provide a singleton lock across executions.
`parallelism: 1` and `replicaCompletionCount: 1` only mean
"one replica per execution"; they do **not** prevent a second
execution (manual or scheduled) of the same job from starting
while a previous one is still running. Two executions of the same
job will run in parallel.

Mitigations, from simplest to strongest:

- **Operational discipline** — same shape as the GHA
  `concurrency:` group: don't dispatch a manual job during the
  scheduled window.
- **Script-level state check** — extend the script with a
  `--check-and-skip` mode that queries `oc get nodes` / VM power
  state and exits cleanly if the cluster is already in the target
  state.
- **External lock** — take an Azure Blob lease at the start of each
  run and release it on exit. If the lease is already held, exit
  cleanly. This works across separate job resources (e.g., shutdown
  and a back-to-back manual startup).

---

## Option 2: Azure Automation + Linux Hybrid Worker

Azure Automation can run bash on a **Linux Hybrid Worker** — a VM (or
Arc-enabled server) you own, with the Automation Hybrid Worker
extension installed. Runbooks live in the Automation account, run on
your worker, and stream output back to the Automation job log.

### When to pick this

- Your org already runs lots of runbooks through Azure Automation
  (this is the standard "Azure ops control plane" pattern in many
  Microsoft customer estates).
- You want all jobs in one Automation pane of glass for audit,
  RBAC, and Log Analytics correlation with other ops activity.
- You already have a Hybrid Worker VM for *something*, and you want
  to add lifecycle automation to it.

### Honest caveat

Hybrid Worker is "a VM you own with an extension on it." If the only
reason you'd stand up a Hybrid Worker VM is OCP lifecycle, the host
cron / systemd timer pattern in `scheduling.md` gives you the same
result with strictly less plumbing. The win is real only when the
worker is shared with other automation.

### Set up the Hybrid Worker

```bash
RG_AUTO=rg-ocp-automation
LOC=eastus
AA=aa-ocp-lifecycle
HWG=ocp-lifecycle-workers
WORKER_VM=vm-ocp-hrw-01

az group create -n "$RG_AUTO" -l "$LOC"
az automation account create -g "$RG_AUTO" -n "$AA" -l "$LOC" \
    --sku Basic

# Hybrid Worker group
az automation hrwg create -g "$RG_AUTO" -n "$HWG" \
    --automation-account-name "$AA"

# Assign system-assigned MI to the worker VM
az vm identity assign -g "$RG_AUTO" -n "$WORKER_VM"
WORKER_PRINCIPAL=$(az vm show -g "$RG_AUTO" -n "$WORKER_VM" \
    --query identity.principalId -o tsv)

# Install the Hybrid Worker VM extension on the VM
# (the portal does this in two clicks; the CLI form is provider-specific
#  and changes; refer to:
#  https://learn.microsoft.com/azure/automation/extension-based-hybrid-runbook-worker-install )

# Grant the worker MI rights it needs
SUB=$(az account show --query id -o tsv)
WORKLOAD_RG=rg-ocp-lab
az role assignment create \
    --assignee-object-id "$WORKER_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/$SUB/resourceGroups/$WORKLOAD_RG"
```

Install `oc`, `jq`, `az`, and the lifecycle scripts on the worker VM
once (same way you would set up a host running cron). The scripts can
live under `/opt/ocp-multus` and update via either:

- a periodic `git pull` from the worker, or
- the Automation account's **Source Control** integration, which pulls
  the runbooks themselves from a GitHub or Azure DevOps Repos branch.

### The bash runbook

Create a runbook of type **Bash** in the Automation account:

```bash
#!/usr/bin/env bash
# ocp-cluster-shutdown.sh — runbook executed on the Hybrid Worker
set -euo pipefail

REPO=/opt/ocp-multus
LOG_DIR=/var/log/ocp-multus
ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$LOG_DIR"
# tee so the Automation job stream sees the output AND we keep a host log.
exec > >(tee -a "$LOG_DIR/cluster-shutdown-${ts}.log") 2>&1

cd "$REPO"

# Path A — Managed Identity on the worker VM (recommended; see below)
az login --identity >/dev/null

# Path B — Service principal alternative (see "Path B" section below for
# how to fetch the SP credential from Key Vault using the worker MI)

# The script reads CLUSTER_SUBSCRIPTION_ID etc. from config/cluster.env;
# that file is provisioned during host setup and survives reboots.
ASSUME_YES=1 OPERATIONS_TIMEOUT_MIN=45 make cluster-shutdown
```

Publish the runbook, then:

1. Create a **Schedule** asset (e.g., "weekday-18-utc",
   `recur every 1 day at 18:00 UTC`).
2. **Link** the schedule to the runbook with the Hybrid Worker group
   `ocp-lifecycle-workers` as the run-on target.
3. Repeat for `ocp-cluster-startup.sh` and a morning schedule.

### Path A — Managed Identity (recommended on the worker)

System-assigned MI on the Hybrid Worker VM is the cleanest auth path:

```bash
az login --identity
```

It picks up the worker's identity automatically. RBAC is scoped at
VM creation time, not at runbook time. Rotation is automatic.

### Path B — Service Principal (alternative)

When the worker is on-prem or Arc-attached and the system MI route
isn't available, store the SP credential in Azure Key Vault, give the
worker's MI (system- or user-assigned) `Key Vault Secrets User` on
the vault, and have the runbook fetch the secret with `az`:

```bash
# Authenticate to Azure first (this still uses the worker MI to read KV)
az login --identity

# Pull SP credential bundle from Key Vault (stored as JSON)
sp_json=$(az keyvault secret show \
    --vault-name "$KV" --name ocp-sp-bundle --query value -o tsv)
ARM_CLIENT_ID=$(jq -r .clientId    <<<"$sp_json")
ARM_CLIENT_SECRET=$(jq -r .clientSecret <<<"$sp_json")
ARM_TENANT_ID=$(jq -r .tenantId    <<<"$sp_json")

# Re-login as the SP so all subsequent az commands run under it
az logout
az login --service-principal \
    -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
```

The SP bundle can be the output of `az ad sp create-for-rbac --json-auth`
stashed as a single Key Vault secret.

> **About Automation native credential assets in Bash.** Azure
> Automation's first-class credential and encrypted-variable assets are
> exposed natively to **PowerShell** runbooks (`Get-AutomationPSCredential`,
> `Get-AutomationVariable`). Bash runbooks don't have an equivalent
> first-party helper. The Key Vault + MI pattern above is the
> idiomatic way to keep secrets out of plain Automation variables for
> Bash. If you must use a native Automation Credential asset, write the
> runbook in PowerShell and shell out to `bash` for the `make` call.

### Log Analytics integration

Link the Automation account to your Log Analytics workspace
(`Diagnostic settings → Send Logs/Metrics to LA`) and the
`AzureDiagnostics` table will start receiving `Category=JobLogs` and
`Category=JobStreams` rows. Filter on
`RunbookName_s in ("ocp-cluster-shutdown","ocp-cluster-startup")` and
set an alert on `ResultType == "Failed"`.

---

## At a glance — alternatives that work with caveats

### Azure Functions (Premium, Linux container, timer trigger)

A `TimerTrigger` function on a Premium plan with a custom Linux
container *can* run bash + `oc` + `az` on a schedule. Key tradeoffs:

- The function timeout on Premium defaults to 30 min and can be
  raised in `host.json` (`functionTimeout`). Set it to at least
  90 min to leave headroom over `OPERATIONS_TIMEOUT_MIN=45m` plus
  the API-up / nodes-Ready waits.
- The Premium plan keeps an instance warm even when idle, so the
  always-on cost floor is higher than ACA Jobs.
- It works, but Container Apps Jobs is just a better-shaped tool for
  the same problem — pick Functions only when you specifically want
  the function programming model (e.g., HTTP-triggered manual run +
  timer-triggered scheduled run in the same app).

### Azure DevOps Pipelines (scheduled)

A scheduled `azure-pipelines.yml` running on a Microsoft-hosted Linux
agent is the direct ADO analog of the GHA pattern in
`scheduling.md`. The shape is identical:

```yaml
schedules:
  - cron: "0 18 * * 1-5"
    displayName: weekday shutdown
    branches: { include: [ main ] }
    always: true
trigger: none
pool:
  vmImage: ubuntu-latest
jobs:
  - job: shutdown
    timeoutInMinutes: 120     # raise from the 60 min default; 360 max on hosted
    variables:
      - group: ocp-lifecycle  # variable group bound to Key Vault for KUBECONFIG_B64
    steps:
      - checkout: self
      - task: AzureCLI@2
        inputs:
          azureSubscription: "ocp-lifecycle-fed"   # workload identity federation
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            set -euo pipefail
            # Install oc into the job workspace
            curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
                -o /tmp/oc.tar.gz
            sudo tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl
            sudo chmod +x /usr/local/bin/oc /usr/local/bin/kubectl
            # Stage kubeconfig from the secret variable
            mkdir -p "$HOME/.kube"
            printf '%s' "$(KUBECONFIG_B64)" | base64 -d > "$HOME/.kube/config"
            chmod 600 "$HOME/.kube/config"
            export KUBECONFIG="$HOME/.kube/config"
            # Stage config/cluster.env from the checked-in example,
            # then override with values from the variable group / pipeline vars.
            cp "$(Build.SourcesDirectory)/config/cluster.example.env" \
               "$(Build.SourcesDirectory)/config/cluster.env"
            sed -i \
              -e "s|^CLUSTER_NAME=.*|CLUSTER_NAME=$(CLUSTER_NAME)|" \
              -e "s|^CLUSTER_SUBSCRIPTION_ID=.*|CLUSTER_SUBSCRIPTION_ID=$(CLUSTER_SUBSCRIPTION_ID)|" \
              -e "s|^WORKLOAD_RESOURCE_GROUP=.*|WORKLOAD_RESOURCE_GROUP=$(WORKLOAD_RESOURCE_GROUP)|" \
              -e "s|^CONTROL_PLANE_VM_PREFIX=.*|CONTROL_PLANE_VM_PREFIX=$(CONTROL_PLANE_VM_PREFIX)|" \
              -e "s|^WORKER_VM_PREFIX=.*|WORKER_VM_PREFIX=$(WORKER_VM_PREFIX)|" \
              -e "s|^SRIOV_WORKER_VM_NAME=.*|SRIOV_WORKER_VM_NAME=$(SRIOV_WORKER_VM_NAME)|" \
              "$(Build.SourcesDirectory)/config/cluster.env"
            cd "$(Build.SourcesDirectory)"
            ASSUME_YES=1 OPERATIONS_TIMEOUT_MIN=45 make cluster-shutdown
```

The pipeline variables (`CLUSTER_NAME`, `CLUSTER_SUBSCRIPTION_ID`, etc.)
come from the `ocp-lifecycle` variable group. Bind the group to Key Vault
so `KUBECONFIG_B64` and any other secrets are sourced from there rather
than checked into the pipeline definition.

Use this when the organization is already on ADO and would rather
not introduce GitHub Actions.

---

## Don't use these for this scenario

| Option | Why not |
|---|---|
| **AKS CronJob** | Chicken-and-egg: if the CronJob lives inside the cluster it is supposed to shut down, the next startup has no schedule pointing at it. A separate AKS cluster *just* for OCP lifecycle is too much overhead. |
| **Azure Batch** | Pool/job/task is a heavy abstraction for two cron-shaped tasks a day. |
| **Logic Apps** | Pure orchestrator — still needs a compute backend (Function, ACI, ACA Job, Automation). If you reach for Logic Apps anyway, the backend has to be one of the options above. |
| **Azure Scheduler (classic)** | Deprecated. Use Logic Apps or one of the recommended options instead. |
| **Azure Update Manager** | Scope is OS patch orchestration. It does not run arbitrary scripts on a schedule for non-patching work. |
| **ACI scheduled via Logic Apps** | Works, but ACI lacks ACA Jobs' first-class scheduled trigger and managed identity ergonomics. ACA Jobs is the modern replacement. |

---

## Cross-cutting concerns

### Where to put the etcd backup

The lifecycle scripts write `backups/<UTC-ts>-<CLUSTER_NAME>/` on the
local filesystem. For any scheduler whose filesystem is ephemeral
(ACA Jobs, Functions, ADO Pipelines) this is not durable storage.
Push to Blob:

```bash
az storage blob upload-batch \
    --account-name <st-acct> \
    --auth-mode login \
    --destination "ocp-backups/$CLUSTER_NAME" \
    --source backups/
```

Set Blob lifecycle management to age out old backups (e.g., hot → cool
at 14 days → delete at 180 days). Use an immutable container if the
audit posture requires WORM.

### kubeconfig delivery

- **Never** commit `~/.kube/config` (or its base64 form) to git.
- **Never** pass it as a plain environment variable in the Azure
  Portal — it shows up in resource configuration exports.
- **Do** keep it in Key Vault and reference it from the scheduler
  (Container Apps secret reference; Automation bash runbook that
  fetches it from KV via the worker's MI; ADO Pipelines secret
  variable group bound to KV).
- Prefer a long-lived `ServiceAccount`-bound token in `kubeconfig`
  over `kube:admin` so you can rotate without re-running install
  procedures.

### Monitoring

Whatever Azure-native option you pick, the same alert pattern works:
query the Log Analytics workspace for a failed run of the scheduler
artifact in the last N hours, and alert if the count is non-zero.
Examples per scheduler:

- ACA Jobs: filter `ContainerAppSystemLogs_CL` on
  `ExecutionStatus_s != "Succeeded"`.
- Automation: filter `AzureDiagnostics` on
  `ResourceType=="AUTOMATIONACCOUNTS"` and `ResultType=="Failed"`.
- Functions: filter `AppRequests` / `traces` for
  `severityLevel >= 3` from your timer function.
- ADO Pipelines: built-in pipeline alerts or webhook to your
  incident system.

### Pre-flight discipline

Before letting any schedule loose unattended:

1. Run `make cluster-status` from the scheduler manually (or just
   read its output from a one-shot job invocation).
2. Run `bash scripts/cluster-shutdown.sh --dry-run --yes` from the
   scheduler.
3. Then a real run during business hours with you watching the logs.
4. Only then enable the schedule and walk away.

If any of those fail, fix the root cause before letting the schedule
fire on its own.

---

## Related

- [`operations.md`](./operations.md) — runbook for every script.
- [`scheduling.md`](./scheduling.md) — GitHub Actions, host cron,
  systemd timers.
- [`docs/scripts/`](./scripts/README.md) — per-script CLI
  reference.
