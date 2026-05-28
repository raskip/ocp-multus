# Installer host requirements

The OpenShift UPI install workflow in this repo runs `terraform`,
`openshift-install`, `oc`, and `az` from a single **installer host**.
This document spells out what that host needs in terms of:

1. Network reach to Azure plus the cluster's internal endpoints.
2. Azure RBAC for the identity that runs the installer.
3. Filesystem state that the installer host must keep across stages.

Most customer-side "demo doesn't work" reports we have seen come down
to an installer host that quietly cannot reach an endpoint the next
`make` target depends on. Walk this checklist *before* `make all`.

> **Why this matters even for UPI.** "User-provisioned" only means
> Terraform owns the Azure resources. `openshift-install` still calls
> ARM (to validate VNets, regions, SKUs, HyperVGeneration) during
> `create manifests` / `create ignition`, and you still need to reach
> the cluster API on port 6443 from the installer host for
> `wait-for bootstrap-complete`, CSR approval, and
> `wait-for install-complete`. There is no "skip-validation" flag that
> avoids the API reach requirement.

## 1. Network reach per `make` target

Every column below is "must work end-to-end from the installer host
shell *before* you run that target". `(API LB)` means the internal
API LoadBalancer that Terraform's `01-network` stack creates; its
private IP lives in `MACHINE_NETWORK_CIDR`.

| Target | Azure ARM (`management.azure.com:443`) | Parent DNS provider | Storage Private Endpoint | Internal API LB :6443 | Notes |
|---|---|---|---|---|---|
| `make tools`              | – | – | – | – | Downloads `openshift-install` + `oc` over public HTTPS only. |
| `make verify`             | ✅ | – | – | – | `az account show` requires reach to ARM + Entra. |
| `make init-config`        | – | – | – | – | Local-only wizard. |
| `make tfvars`             | – | – | – | – | Renders `from-env.auto.tfvars`. No network. |
| `make preflight`          | ✅ | ✅ | – | – | Reads roles / quotas / DNS. See [`docs/preflight-checklist.md`](./preflight-checklist.md) for what each sub-check verifies and how to fix common findings. |
| `make prereqs`            | ✅ | ✅ | – | – | Terraform creates the workload RG, storage account, parent-zone NS-record (cross-sub provider). |
| `make network`            | ✅ | – | – | – | Terraform creates VNet child resources, ILBs, the uploader VM, and the storage PE. |
| `make image`              | ✅ | – | indirect (via uploader VM) | – | RHCOS VHD is streamed through the uploader VM because the storage account is PE-only. |
| `make install-config`     | ✅ | – | – | – | `openshift-install create manifests` validates ARM. **Requires `~/.azure/osServicePrincipal.json`.** |
| `make ignition`           | ✅ | – | – | – | Same SP requirement. Writes `install/*.ign`. |
| `make bootstrap`          | ✅ | – | indirect | – | Bootstrap-ignition pointer is uploaded through the uploader VM. |
| `make control-plane`      | ✅ | – | – | – | Terraform creates master VMs; they pull their ignition over the storage PE. |
| `make wait-bootstrap`     | ✅ | resolves `api.<cluster>.<base>` | – | **✅** | First moment the installer host must reach the cluster API. |
| `make destroy-bootstrap`  | ✅ | – | – | – | Removes the bootstrap VM. |
| `make workers`            | ✅ | – | – | ✅ | Worker kubelets create CSRs that the installer host must approve via the API LB. |
| `make wait-install`       | ✅ | resolves cluster FQDNs | – | **✅** | Backgrounds the CSR approver + waits for all ClusterOperators Available. |
| `make destroy`            | ✅ | – | – | – | Tears everything down in reverse order. |

If any of those checkmarks is impossible from the installer host's
network position you will fail at exactly the listed target — usually
with a misleading error such as `dial tcp ... i/o timeout` or
`x509: certificate signed by unknown authority` (when a TLS-inspecting
firewall sits in the middle). TLS inspection is not just an outbound
allowlist problem: the current repo does not yet auto-render OpenShift
`proxy:` / `additionalTrustBundle` settings from `config/cluster.env`,
so treat it as a pre-workshop design item.

## 2. Azure RBAC requirements

The identity that runs `terraform` and `openshift-install` needs both
**install-time** and **runtime** rights. Manual cloud-credential mode
does *not* let you skip the runtime grants — see
`docs/azure-identity-options.md` (added in a separate PR) for the full
breakdown.

| Scope | Role(s) | Why |
|---|---|---|
| Subscription (cluster sub) | **Reader** | `openshift-install` validates locations, SKUs, HyperVGeneration via ARM. |
| Workload resource group (`$WORKLOAD_RESOURCE_GROUP`) | **Contributor** | Cluster runtime creates load balancers, public IPs, disks, etc. |
| Network resource group (`$NETWORK_RESOURCE_GROUP`) | **Network Contributor** | Cluster runtime updates NSG rules + adds backend pool members. |
| Parent DNS resource group (`$PARENT_DNS_RESOURCE_GROUP`) | **DNS Zone Contributor** (cross-sub) | `make prereqs` adds the sub-zone NS-record into the parent zone. |

For BYO-network deployments (set `manage_network_resources = false`
in `terraform/01-network/`) you can scope the network role tighter —
see [`docs/network-prereqs.md`](./network-prereqs.md) for the minimum
NSG / route table / subnet rights.

## 3. Filesystem state

`openshift-install` keeps its state in `$INSTALL_DIR`
(default `install/`). The contents below must survive between the
`ignition` and `wait-install` targets:

| Path | Created by | Required by |
|---|---|---|
| `install/metadata.json` | `make ignition` | `make destroy`, `make tfvars` (canonical `infra_id`) |
| `install/auth/kubeconfig` | `wait-for bootstrap-complete` | every target that talks to the cluster API |
| `install/auth/kubeadmin-password` | `wait-for bootstrap-complete` | console login |
| `install/*.ign` | `make ignition` | `make bootstrap` / `make control-plane` / `make workers` |
| `~/.azure/osServicePrincipal.json` (mode `0600`) | first interactive install OR `az ad sp create-for-rbac` | every `openshift-install` invocation |

If you run the install on a throw-away VM, keep these files on a
persistent volume — otherwise a recycled VM cannot run `make destroy`
without manual cleanup of orphaned Azure resources.

## 4. Reaching the internal API LB from the installer host

The repo defaults to `publish: Internal`, so the cluster API has a
private IP only. The installer host therefore needs *one* of:

| Pattern | Description | When it fits |
|---|---|---|
| **A. Direct PIP on jump VM** | Jump VM in the spoke VNet with a public IP that you SSH into | Greenfield dev tenants without policy restrictions. **Often blocked by enterprise security policy.** |
| **B. Hub firewall DNAT** | Workstation → hub firewall public IP → DNAT to jump VM SSH (or to API LB :6443) | Hub-spoke topologies where the security team already owns a centralised firewall. |
| **C. Azure Bastion** | Bastion in the spoke VNet, SSH tunnel from workstation via the portal or `az network bastion tunnel` | Highest enterprise compatibility; no public IPs on the jump host. |
| **D. Private-only (VPN / ExpressRoute)** | On-prem workstation reaches the spoke VNet via existing connectivity, no public IP at all | Production-realistic. Requires the corporate WAN to extend to the cluster spoke. |

The repo's optional Windows browser/RDP jump host
(`CREATE_WINDOWS_JUMP=true`) is only a convenience for accessing an
internal OpenShift console. It is disabled by default and is not
required for `make all`; the Linux examples in
`examples/jump-host-access/` or a customer-provided host are the normal
installer-host patterns.

See `docs/jump-host-access-decision.md` for the full decision tree
and `examples/jump-host-access/` for working Terraform snippets per
pattern.

## 5. Quick self-check

**Easiest:** run `make verify` from the repo root — it checks all
required host tools (bash, make, jq, az, terraform) and that
`config/cluster.env` + the SP credential file are in place.

For ad-hoc checks (or if you can't run `make` yet), this snippet
covers the same Azure-reach surface from the installer host before
`make all`:

```bash
# 1. Azure ARM + identity
az account show --query '{name:name,id:id,user:user.name}' -o table

# 2. Parent DNS reach (replace with your zone)
az network dns zone show -g "$PARENT_DNS_RESOURCE_GROUP" -n "$PARENT_DNS_ZONE" \
  --subscription "$DNS_SUBSCRIPTION_ID" --query name -o tsv

# 3. SP file present + readable
test -r ~/.azure/osServicePrincipal.json && \
  jq -e '.clientId and .clientSecret and .tenantId and .subscriptionId' \
    ~/.azure/osServicePrincipal.json >/dev/null && echo "SP file OK"

# 4. After `make network` only: can you reach the internal API LB?
#    (Replace with your actual API LB private IP from terraform output.)
nc -zv "$API_LB_PRIVATE_IP" 6443
```

If any of those fail, fix the gap before running the next `make`
target. Most install failures we see are reachability problems that
the installer host masks behind a Terraform or `openshift-install`
error message that does not point at the underlying network issue.
