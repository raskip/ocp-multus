# Scheduling cluster shutdown / startup

This guide covers running the lifecycle scripts on a schedule so the
cluster pauses overnight (or over the weekend) and comes back up
automatically before working hours.

Read [`OPERATIONS.md`](./OPERATIONS.md) first for what each command
does and the safety model. This document focuses on *how to schedule
them* via **GitHub Actions, host cron, or systemd timers**.

> **Looking for Azure-native automation?** See
> [`AZURE-AUTOMATION.md`](./AZURE-AUTOMATION.md) for Azure Container
> Apps Jobs, Azure Automation + Linux Hybrid Worker, Azure Functions,
> and Azure DevOps Pipelines — including a decision matrix and a
> "don't use these" list.

> **Discipline for any scheduled run**
>
> - **Never schedule `--fast`.** Use the default `--graceful` flow. The
>   speed difference is not worth the etcd corruption risk on a
>   recurring trigger.
> - **Always take an etcd backup.** The default `cluster-shutdown`
>   does. Don't pass `--no-backup` on a schedule.
> - **Always use `--yes`** (or `ASSUME_YES=1`) so there's no prompt to
>   block automation.
> - **Pin a long enough `--timeout`** for your cluster size. The
>   default `OPERATIONS_TIMEOUT_MIN=30` is fine for small UPI clusters;
>   larger clusters need more.
> - **Make sure tokens / credentials don't expire mid-run.** See the
>   "Authentication freshness" section for each scheduler.
> - **Monitor it.** A scheduled shutdown that quietly fails is worse
>   than no schedule at all.

---

## Option A: GitHub Actions (recommended for teams)

The repo ships an example workflow at
[`.github/workflows/cluster-lifecycle.example.yml.disabled`](./.github/workflows/cluster-lifecycle.example.yml.disabled).
It handles `workflow_dispatch` (manual runs) for one-off operations.

For *scheduled* runs the cleanest pattern is **two small workflows**:
one for shutdown on an evening cron, one for startup on a morning cron.
This keeps the schedule trigger and the action it performs explicit, so
the audit trail is unambiguous.

### 1. Configure secrets

In **Settings → Secrets and variables → Actions → Secrets**:

| Secret | What it is |
|---|---|
| `AZURE_CLIENT_ID`       | Entra app client id used for federated workload identity |
| `AZURE_TENANT_ID`       | Entra tenant id |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing the cluster VMs |
| `KUBECONFIG_B64`        | `base64 -w0 < ~/.kube/config` with a long-lived cluster-admin context |

Configure the Azure side per
[Connect from Azure to GitHub Actions with OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure).
The federated credential subject claim should target the *branch* the
workflow runs from (typically `main`).

### 2. Configure variables

In **Settings → Secrets and variables → Actions → Variables**:

| Variable | What it is | Required? |
|---|---|---|
| `CLUSTER_NAME`              | Cluster name suffix used in VM names (e.g. `lab`) | yes |
| `WORKLOAD_RESOURCE_GROUP`   | Resource group containing the cluster VMs         | yes |
| `CONTROL_PLANE_VM_PREFIX`   | Defaults to `vm-master`                           | no  |
| `WORKER_VM_PREFIX`          | Defaults to `vm-worker`                           | no  |
| `SRIOV_WORKER_VM_NAME`      | Defaults to `vm-worker-sriov`                     | no  |

These let the workflow build a real `config/cluster.env` at runtime,
instead of hard-coding values into the workflow file.

### 3. Drop in the two scheduled workflows

`.github/workflows/cluster-shutdown.yml`:

```yaml
name: cluster-shutdown
on:
  schedule:
    - cron: "0 16 * * 1-5"      # 16:00 UTC weekdays — adjust for your TZ
  workflow_dispatch: {}

permissions:
  id-token: write
  contents: read

# Prevent overlap with the startup workflow or a manual dispatch.
concurrency:
  group: ocp-multus-lifecycle
  cancel-in-progress: false

jobs:
  shutdown:
    runs-on: ubuntu-latest
    env:
      ASSUME_YES: "1"
      OPERATIONS_TIMEOUT_MIN: "45"
    steps:
      - uses: actions/checkout@v4

      - name: Install oc, jq
        run: |
          set -euo pipefail
          curl -sSLO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
          tar -xzf openshift-client-linux.tar.gz oc kubectl
          sudo mv oc kubectl /usr/local/bin/

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id:       ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Stage kubeconfig and cluster.env
        env:
          CLUSTER_NAME:            ${{ vars.CLUSTER_NAME }}
          WORKLOAD_RESOURCE_GROUP: ${{ vars.WORKLOAD_RESOURCE_GROUP }}
          CONTROL_PLANE_VM_PREFIX: ${{ vars.CONTROL_PLANE_VM_PREFIX }}
          WORKER_VM_PREFIX:        ${{ vars.WORKER_VM_PREFIX }}
          SRIOV_WORKER_VM_NAME:    ${{ vars.SRIOV_WORKER_VM_NAME }}
        run: |
          set -euo pipefail
          : "${CLUSTER_NAME:?repo variable CLUSTER_NAME is required}"
          : "${WORKLOAD_RESOURCE_GROUP:?repo variable WORKLOAD_RESOURCE_GROUP is required}"
          mkdir -p "$HOME/.kube"
          printf '%s' "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > "$HOME/.kube/config"
          chmod 600 "$HOME/.kube/config"
          {
            echo "CLUSTER_NAME=${CLUSTER_NAME}"
            echo "WORKLOAD_RESOURCE_GROUP=${WORKLOAD_RESOURCE_GROUP}"
            echo "CLUSTER_SUBSCRIPTION_ID=${{ secrets.AZURE_SUBSCRIPTION_ID }}"
            [[ -n "${CONTROL_PLANE_VM_PREFIX}" ]] && echo "CONTROL_PLANE_VM_PREFIX=${CONTROL_PLANE_VM_PREFIX}"
            [[ -n "${WORKER_VM_PREFIX}"        ]] && echo "WORKER_VM_PREFIX=${WORKER_VM_PREFIX}"
            [[ -n "${SRIOV_WORKER_VM_NAME}"    ]] && echo "SRIOV_WORKER_VM_NAME=${SRIOV_WORKER_VM_NAME}"
          } > config/cluster.env

      - name: Run graceful shutdown
        run: make cluster-shutdown

      - name: Upload etcd backup
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: etcd-backup-${{ github.run_id }}
          path: backups/**
          if-no-files-found: ignore
          retention-days: 30
```

`.github/workflows/cluster-startup.yml`:

```yaml
name: cluster-startup
on:
  schedule:
    - cron: "0 6 * * 1-5"       # 06:00 UTC weekdays — adjust for your TZ
  workflow_dispatch: {}

permissions:
  id-token: write
  contents: read

# Share the lifecycle concurrency group with the shutdown workflow.
concurrency:
  group: ocp-multus-lifecycle
  cancel-in-progress: false

jobs:
  startup:
    runs-on: ubuntu-latest
    env:
      OPERATIONS_TIMEOUT_MIN: "45"
    steps:
      - uses: actions/checkout@v4

      - name: Install oc, jq
        run: |
          set -euo pipefail
          curl -sSLO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
          tar -xzf openshift-client-linux.tar.gz oc kubectl
          sudo mv oc kubectl /usr/local/bin/

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id:       ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Stage kubeconfig and cluster.env
        env:
          CLUSTER_NAME:            ${{ vars.CLUSTER_NAME }}
          WORKLOAD_RESOURCE_GROUP: ${{ vars.WORKLOAD_RESOURCE_GROUP }}
          CONTROL_PLANE_VM_PREFIX: ${{ vars.CONTROL_PLANE_VM_PREFIX }}
          WORKER_VM_PREFIX:        ${{ vars.WORKER_VM_PREFIX }}
          SRIOV_WORKER_VM_NAME:    ${{ vars.SRIOV_WORKER_VM_NAME }}
        run: |
          set -euo pipefail
          : "${CLUSTER_NAME:?repo variable CLUSTER_NAME is required}"
          : "${WORKLOAD_RESOURCE_GROUP:?repo variable WORKLOAD_RESOURCE_GROUP is required}"
          mkdir -p "$HOME/.kube"
          printf '%s' "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > "$HOME/.kube/config"
          chmod 600 "$HOME/.kube/config"
          {
            echo "CLUSTER_NAME=${CLUSTER_NAME}"
            echo "WORKLOAD_RESOURCE_GROUP=${WORKLOAD_RESOURCE_GROUP}"
            echo "CLUSTER_SUBSCRIPTION_ID=${{ secrets.AZURE_SUBSCRIPTION_ID }}"
            [[ -n "${CONTROL_PLANE_VM_PREFIX}" ]] && echo "CONTROL_PLANE_VM_PREFIX=${CONTROL_PLANE_VM_PREFIX}"
            [[ -n "${WORKER_VM_PREFIX}"        ]] && echo "WORKER_VM_PREFIX=${WORKER_VM_PREFIX}"
            [[ -n "${SRIOV_WORKER_VM_NAME}"    ]] && echo "SRIOV_WORKER_VM_NAME=${SRIOV_WORKER_VM_NAME}"
          } > config/cluster.env

      - name: Run startup
        run: make cluster-startup
```

> **`cluster-startup` exit code = full health.** Since the recent
> hardening, `cluster-startup.sh` exits non-zero if cluster operators
> do not converge or if etcd health fails. A green workflow run
> therefore means a healthy cluster, not just "VMs started." This is
> the behavior you want for unattended automation.

### Cron syntax notes

- GitHub Actions cron is in **UTC**.
- Adjust for your local timezone, including daylight-saving transitions
  (or just pick a UTC time you're comfortable with year-round).
- Scheduled workflows can be delayed by Actions backlog — don't expect
  second-accurate triggering.
- Workflows that haven't run in 60 days get disabled automatically
  unless you `workflow_dispatch` them manually now and then.

### Authentication freshness

The federated OIDC token is short-lived and minted at workflow start;
no human action needed. The `KUBECONFIG_B64` secret, however, contains
whatever credentials you put in it:

- Prefer a kubeconfig backed by a long-lived `ServiceAccount` token
  bound to `cluster-admin` (or to the minimum needed roles — `nodes`,
  `clusteroperators`, `csr` approval, `oc debug`, `pods/exec` in
  `openshift-etcd`).
- Don't use a kubeconfig from `oc login` against an OAuth provider —
  those tokens typically expire within 24 hours and will leave the
  cluster orphaned at the next scheduled run.

---

## Option B: Linux/macOS cron (single host)

If you don't want a GitHub Actions setup, a small Linux box (or your
laptop) can run the same commands.

### 1. One-time setup on the host

```bash
# Clone the repo somewhere stable
git clone https://github.com/raskip/ocp-multus.git /opt/ocp-multus
cd /opt/ocp-multus

# Real cluster config (this file is gitignored)
cp config/cluster.example.env config/cluster.env
$EDITOR config/cluster.env

# Tools (check your distro)
sudo apt-get install -y jq make

# oc client (pick a version matching your cluster)
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
  | sudo tar -xz -C /usr/local/bin oc kubectl

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Make sure `oc whoami` and `az account show` work as the user that will
own the cron job.

### 2. Wrapper script (lock + log + auth refresh)

Drop this at `/opt/ocp-multus/scripts/cron-cluster-shutdown.sh`:

```bash
#!/usr/bin/env bash
# Wrapper for scheduled cluster shutdown via cron. Uses flock(1) to
# prevent overlapping runs and tees output to a dated log file.
set -euo pipefail

REPO=/opt/ocp-multus
LOG_DIR=/var/log/ocp-multus
LOCK=/var/lock/ocp-multus.lock
ts=$(date -u +%Y%m%dT%H%M%SZ)

mkdir -p "$LOG_DIR"

# Acquire the lock BEFORE redirecting output, so that a missed lock
# acquisition is reported to cron's MAILTO recipient.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another ocp-multus lifecycle run holds $LOCK; aborting" >&2
  exit 1
fi

# Now redirect everything to a per-run log file.
exec >>"$LOG_DIR/cluster-shutdown-${ts}.log" 2>&1

cd "$REPO"

# Use a long-lived kubeconfig that does not depend on a user login session.
export KUBECONFIG=/root/.kube/config

# Refresh the Azure subscription context. Assumes the credential
# (service principal or managed identity) was set up once previously.
sub=$(grep '^CLUSTER_SUBSCRIPTION_ID=' config/cluster.env | cut -d= -f2 || true)
if [[ -n "$sub" ]]; then
  az account set --subscription "$sub" >/dev/null 2>&1 || true
fi

ASSUME_YES=1 OPERATIONS_TIMEOUT_MIN=45 make cluster-shutdown
```

And a matching `cron-cluster-startup.sh` (same shape, swap the `make`
target). `chmod +x` both.

> **Why this pattern**
>
> - `exec 9>$LOCK; flock -n 9` uses a Bash file-descriptor lock instead of
>   `flock -c "..."`. `flock -c` runs the command through `/bin/sh`, which
>   on Debian/Ubuntu is `dash`. `dash` does not support `set -o pipefail`,
>   so a script with strict Bash options will fail immediately under
>   `flock -c`. The FD form keeps us in our own Bash process throughout.
> - The lock is acquired *before* output redirection so that a stuck
>   previous run produces a real failure email from cron, not a silent
>   line in a log file.

### 3. crontab

`crontab -e` as the user that owns `KUBECONFIG` and the Azure
credential (often root for unattended hosts):

```cron
# Cron runs in the system timezone unless CRON_TZ is set
CRON_TZ=Europe/Helsinki

# 18:00 weekdays — graceful shutdown
0 18 * * 1-5  /opt/ocp-multus/scripts/cron-cluster-shutdown.sh

# 08:00 weekdays — startup
0  8 * * 1-5  /opt/ocp-multus/scripts/cron-cluster-startup.sh
```

### Timezone caveats

- `CRON_TZ` is honored by most modern crons (vixie-cron on Debian/Ubuntu,
  cronie on RHEL/Fedora). On macOS `launchd` is the better choice.
- If `CRON_TZ` is unsupported on your platform, use UTC and translate
  manually.

### Log rotation

The wrapper writes one file per run. Add `/etc/logrotate.d/ocp-multus`:

```
/var/log/ocp-multus/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

### Authentication freshness on a host

- For unattended runs, use a **service principal** with `Virtual Machine
  Contributor` on the workload resource group and stash the credential
  via `az login --service-principal`. Refresh the cached token in the
  wrapper if your install nukes it on reboot.
- On an Azure VM, `az login --identity` is the cleanest option (no
  secret on disk).
- For `oc`, prefer a `ServiceAccount` token bound to a role suitable
  for these scripts (see the GitHub Actions section above for the
  permission list). Avoid OAuth tokens from `oc login`.

---

## Option C: systemd timer + service (single host, modern Linux)

If you prefer systemd over cron, use a service unit + timer unit pair
per direction.

`/etc/systemd/system/ocp-multus-shutdown.service`:

```ini
[Unit]
Description=OpenShift cluster graceful shutdown
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/ocp-multus
Environment=ASSUME_YES=1
Environment=OPERATIONS_TIMEOUT_MIN=45
Environment=KUBECONFIG=/root/.kube/config
# Drop privileges or use a service account if you can.
ExecStart=/usr/bin/make cluster-shutdown
StandardOutput=append:/var/log/ocp-multus/cluster-shutdown.log
StandardError=inherit
TimeoutStartSec=2h
```

`/etc/systemd/system/ocp-multus-shutdown.timer`:

```ini
[Unit]
Description=Graceful cluster shutdown on weekday evenings

[Timer]
# Local time; the cluster operator typically wants 18:00 weekday evenings
OnCalendar=Mon..Fri 18:00
# false: never catch up missed shutdowns — never shut down mid-morning
# because the host was offline at 18:00 yesterday.
Persistent=false
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
```

Mirror these as `ocp-multus-startup.service` (swap `cluster-shutdown` for
`cluster-startup`) and `ocp-multus-startup.timer`
(`OnCalendar=Mon..Fri 08:00`, but set `Persistent=true` on the startup
timer so a missed startup catches up).

Enable and verify:

```bash
sudo mkdir -p /var/log/ocp-multus
sudo systemctl daemon-reload
sudo systemctl enable --now ocp-multus-shutdown.timer
sudo systemctl enable --now ocp-multus-startup.timer
systemctl list-timers ocp-multus-*
journalctl -u ocp-multus-shutdown.service -e
```

### Why `Persistent=` differs between startup and shutdown

If the host was off at the scheduled time, a `Persistent=true` timer
fires when it comes back up. For startup that's exactly what you want
(a missed morning startup catches up). For shutdown that's the wrong
behavior, because a host that was offline at 18:00 yesterday could
then fire a shutdown at 11:00 the next day, mid-workday. Keep
`Persistent=false` on the shutdown timer.

### Authentication freshness

Same as the cron section: stash a service principal credential, or
use `az login --identity` on an Azure VM, and back the kubeconfig with
a long-lived `ServiceAccount` token.

---

## Verifying a schedule works end to end

Before relying on the schedule, dry-run it manually:

```bash
# Validate the lifecycle scripts find your cluster:
make cluster-status

# Dry-run the destructive command:
bash scripts/cluster-shutdown.sh --dry-run --yes

# Then a real run, off-hours, with you watching the logs.
make cluster-shutdown
```

After the first real scheduled run, audit:

- The expected workflow / cron entry / timer actually fired.
- `make cluster-status` post-run reports all VMs `deallocated`.
- An etcd backup landed in `backups/` (or the GHA artifact store).
- The morning startup brought every node back Ready and every
  clusteroperator green.
- The startup run's exit code was `0`. Since the recent hardening,
  `cluster-startup.sh` fails (exits non-zero) if clusteroperators do not
  converge or if etcd health does not pass — so a green workflow /
  successful systemd unit really does mean a healthy cluster, not just
  "VMs started." If the startup unit reports failure, run
  `make cluster-status` and inspect the log file before retrying.

If any of those fail, fix the root cause before letting the schedule
loose unattended.

---

## Alternative: Azure-native automation

If you'd rather not run GitHub Actions, host cron, or a systemd
timer — for example, your organization standardizes on Azure ops
tooling — there are good Azure-native alternatives covered in their
own document:

- **Azure Container Apps Jobs** (recommended default for the
  Azure-native path)
- **Azure Automation + Linux Hybrid Worker**
- Azure Functions and Azure DevOps Pipelines (at-a-glance)
- Plus a "don't use these" list for AKS CronJob / Batch / Logic Apps
  on their own / Azure Scheduler / Azure Update Manager

See [`AZURE-AUTOMATION.md`](./AZURE-AUTOMATION.md) for the decision
matrix and full walkthroughs.
