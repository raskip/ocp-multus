#!/usr/bin/env bash
# Shared helpers for cluster lifecycle scripts (shutdown, startup, etcd backup,
# worker scaling, status). Sourced, never executed directly.
#
# Provides:
#   - REPO_ROOT       absolute path of the repository root
#   - log_info/warn/err
#   - require_cmd     verify a command is on PATH
#   - load_config     load config/cluster.env into the environment
#   - require_vars    fail if env vars are unset
#   - require_oc      verify oc is logged in and points to the expected cluster
#   - require_az      verify az is logged in and select the cluster subscription
#   - confirm         interactive yes/no prompt (skippable with --yes / ASSUME_YES=1)
#   - vm_inventory    print Azure VM inventory for the cluster
#                       writes lines: "<role>\t<name>\t<powerState>"
#                       roles: master | worker | sriov-worker | bootstrap
#   - vm_id_list      print --ids list for a given role filter
#   - api_vip_node    print the control plane node currently serving the API VIP
#   - approve_node_csrs
#                     approve pending kubelet-client + kubelet-serving CSRs for
#                     system:node:* requesters; safe to run repeatedly
#   - wait_for_api    block until `oc get nodes` succeeds (with timeout)
#   - wait_for_nodes_ready
#                     block until all nodes (or a given selector) report Ready
#   - wait_for_cluster_operators
#                     block until all clusteroperators are Available + !Progressing + !Degraded
#   - cert_expiry     print kube-apiserver-to-kubelet-signer not-after annotation
#
# All helpers honor DRY_RUN=1: side-effecting operations are logged but skipped.
set -euo pipefail

if [[ -z "${OCP_LIFECYCLE_LIB_LOADED:-}" ]]; then
  OCP_LIFECYCLE_LIB_LOADED=1
else
  return 0 2>/dev/null || true
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --- logging --------------------------------------------------------------

_log_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { printf '[%s] [INFO]  %s\n'  "$(_log_ts)" "$*" >&2; }
log_warn() { printf '[%s] [WARN]  %s\n'  "$(_log_ts)" "$*" >&2; }
log_err()  { printf '[%s] [ERROR] %s\n'  "$(_log_ts)" "$*" >&2; }
log_step() { printf '\n[%s] === %s ===\n' "$(_log_ts)" "$*" >&2; }

# --- prerequisite tools ---------------------------------------------------

require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    log_err "missing required commands: ${missing[*]}"
    return 1
  fi
}

# --- config loading -------------------------------------------------------

load_config() {
  local config_file="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"
  if [[ ! -f "$config_file" ]]; then
    log_err "config file not found: $config_file"
    log_err "copy $REPO_ROOT/config/cluster.example.env to that location and adjust it"
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$config_file"
  set +a
  : "${CLUSTER_NAME:?CLUSTER_NAME required in $config_file}"
  : "${WORKLOAD_RESOURCE_GROUP:?WORKLOAD_RESOURCE_GROUP required in $config_file}"
  : "${CONTROL_PLANE_VM_PREFIX:=vm-master}"
  : "${WORKER_VM_PREFIX:=vm-worker}"
  : "${SRIOV_WORKER_VM_NAME:=vm-worker-sriov}"
  : "${BOOTSTRAP_VM_NAME:=vm-bootstrap}"
  : "${BACKUP_DIR:=backups}"
  : "${OPERATIONS_TIMEOUT_MIN:=30}"
  export CLUSTER_NAME WORKLOAD_RESOURCE_GROUP \
         CONTROL_PLANE_VM_PREFIX WORKER_VM_PREFIX SRIOV_WORKER_VM_NAME \
         BOOTSTRAP_VM_NAME BACKUP_DIR OPERATIONS_TIMEOUT_MIN
}

require_vars() {
  local missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    log_err "missing required env vars: ${missing[*]}"
    return 1
  fi
}

# --- oc / kubectl ---------------------------------------------------------

require_oc() {
  # B45: PATH fallback so users don't need `sudo cp ./oc /usr/local/bin/`
  # after `make tools`. If `oc` isn't on PATH but $REPO_ROOT/oc exists, use it.
  if ! command -v oc >/dev/null 2>&1 && [[ -x "$REPO_ROOT/oc" ]]; then
    export PATH="$REPO_ROOT:$PATH"
    log_info "added $REPO_ROOT to PATH (found ./oc)"
  fi
  require_cmd oc
  if ! oc whoami >/dev/null 2>&1; then
    log_err "oc is not logged in to a cluster (try: oc login ...)"
    return 1
  fi
  local server
  server=$(oc whoami --show-server 2>/dev/null || true)
  log_info "oc context: $(oc whoami) @ $server"
}

# --- az -------------------------------------------------------------------

require_az() {
  require_cmd az
  if ! az account show -o none >/dev/null 2>&1; then
    # B46: SP-auth fallback for non-interactive environments (WSL2, CI).
    # Order: (1) env vars AZURE_CLIENT_ID/SECRET/TENANT_ID,
    #        (2) JSON file at $AZURE_SP_JSON or ~/.azure/osServicePrincipal.json
    #            (the same file openshift-install creates for UPI installs).
    local sp_json="${AZURE_SP_JSON:-$HOME/.azure/osServicePrincipal.json}"
    if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
      log_info "az not logged in; attempting SP login from env vars"
      az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" \
        --tenant "$AZURE_TENANT_ID" -o none \
        || { log_err "SP login from env vars failed"; return 1; }
    elif [[ -f "$sp_json" ]] && command -v jq >/dev/null 2>&1; then
      log_info "az not logged in; attempting SP login from $sp_json"
      local cid cs tid
      cid=$(jq -r '.clientId // empty'     "$sp_json")
      cs=$(jq  -r '.clientSecret // empty' "$sp_json")
      tid=$(jq -r '.tenantId // empty'     "$sp_json")
      if [[ -z "$cid" || -z "$cs" || -z "$tid" ]]; then
        log_err "$sp_json is missing clientId/clientSecret/tenantId"
        return 1
      fi
      az login --service-principal -u "$cid" -p "$cs" --tenant "$tid" -o none \
        || { log_err "SP login from $sp_json failed"; return 1; }
    else
      log_err "az is not logged in (try: az login, OR set AZURE_CLIENT_ID/AZURE_CLIENT_SECRET/AZURE_TENANT_ID, OR create $sp_json)"
      return 1
    fi
  fi
  if [[ -n "${CLUSTER_SUBSCRIPTION_ID:-}" ]]; then
    log_info "selecting az subscription: $CLUSTER_SUBSCRIPTION_ID"
    az account set --subscription "$CLUSTER_SUBSCRIPTION_ID"
  fi
  local sub
  sub=$(az account show --query '{name:name,id:id}' -o tsv | tr '\t' ' ')
  log_info "az subscription: $sub"
}

# --- confirmation ---------------------------------------------------------

ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
AUTO_APPROVE_CSRS="${AUTO_APPROVE_CSRS:-1}"

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "$ASSUME_YES" == "1" ]]; then
    log_info "$prompt [auto-yes]"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_err "$prompt (non-interactive shell; pass --yes to confirm)"
    return 1
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- Azure VM inventory ---------------------------------------------------

# Print one line per cluster VM: "<role>\t<name>\t<powerState>"
# Roles: master | worker | sriov-worker | bootstrap
# Names must match exact patterns derived from Terraform:
#   master:        ^${CONTROL_PLANE_VM_PREFIX}-[0-9]+-${CLUSTER_NAME}$
#   worker:        ^${WORKER_VM_PREFIX}-[0-9]+-${CLUSTER_NAME}$
#   sriov-worker:  exactly ${SRIOV_WORKER_VM_NAME}-${CLUSTER_NAME}
#   bootstrap:     exactly ${BOOTSTRAP_VM_NAME}-${CLUSTER_NAME}
# Anything else is ignored.
vm_inventory() {
  require_cmd az jq
  local rows
  if ! rows=$(az vm list \
        --resource-group "$WORKLOAD_RESOURCE_GROUP" \
        --show-details \
        --query "[].{name:name, power:powerState}" \
        -o json 2>&1); then
    log_err "az vm list failed for resource group $WORKLOAD_RESOURCE_GROUP:"
    log_err "$rows"
    return 1
  fi
  printf '%s\n' "$rows" | jq -r --arg cn "$CLUSTER_NAME" \
    --arg mp "$CONTROL_PLANE_VM_PREFIX" \
    --arg wp "$WORKER_VM_PREFIX" \
    --arg sw "$SRIOV_WORKER_VM_NAME" \
    --arg bs "$BOOTSTRAP_VM_NAME" '
      def role(n):
        if n == ($bs + "-" + $cn) then "bootstrap"
        elif n == ($sw + "-" + $cn) then "sriov-worker"
        elif (n | test("^" + $mp + "-[0-9]+-" + $cn + "$")) then "master"
        elif (n | test("^" + $wp + "-[0-9]+-" + $cn + "$")) then "worker"
        else "other" end;
      .[] | select(role(.name) != "other")
          | [role(.name), .name, (.power // "Unknown")] | @tsv'
}

# Print Azure --ids for VMs matching given roles (space-separated list).
# Usage: vm_id_list master worker sriov-worker
vm_id_list() {
  require_cmd az
  local roles=("$@")
  local names=()
  local inv
  if ! inv=$(vm_inventory); then
    log_err "vm_inventory failed; cannot enumerate VM IDs"
    return 1
  fi
  if [[ -z "$inv" ]]; then
    return 0
  fi
  while IFS=$'\t' read -r role name _; do
    [[ -z "$role" ]] && continue
    for r in "${roles[@]}"; do
      [[ "$role" == "$r" ]] && names+=("$name") && break
    done
  done <<< "$inv"
  if (( ${#names[@]} == 0 )); then
    return 0
  fi
  for n in "${names[@]}"; do
    az vm show --resource-group "$WORKLOAD_RESOURCE_GROUP" --name "$n" --query id -o tsv
  done
}

# --- cluster introspection ------------------------------------------------

# Best-effort hint at which control plane node should be shut down last.
# On Azure UPI the API VIP is a Standard Load Balancer frontend IP — it is
# NOT pinned to one master — so this function is only an ordering hint, not
# a strict invariant like on platforms with keepalived/VRRP-based VIPs.
# We deliberately pick a deterministic master (the one whose IP appears in
# the kubernetes endpoints, falling back to the alphabetically last master)
# so that the shutdown loop has a stable "process last" target.
last_master_for_shutdown() {
  require_cmd oc
  local vip_ip
  vip_ip=$(oc get endpoints -n default kubernetes \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [[ -n "$vip_ip" ]]; then
    local node
    node=$(oc get nodes -l node-role.kubernetes.io/master \
      -o jsonpath='{range .items[?(@.status.addresses[?(@.address=="'"$vip_ip"'")])]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | head -n1 || true)
    if [[ -n "$node" ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  fi
  oc get nodes -l node-role.kubernetes.io/master \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort | tail -n1
}

# Backward-compatible alias.
api_vip_node() { last_master_for_shutdown; }

# Print the kube-apiserver-to-kubelet signer expiry timestamp.
cert_expiry() {
  require_cmd oc
  oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer \
    -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null || true
}

# --- CSR auto-approval ----------------------------------------------------

# Approve all *pending* CSRs that are either:
#   - kubelet-client (signerName = kubernetes.io/kube-apiserver-client-kubelet)
#       requester groups: system:nodes / system:node:<name> / system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
#   - kubelet-serving (signerName = kubernetes.io/kubelet-serving)
#       requester: system:node:<name>
# Anything else is left alone and reported.
approve_node_csrs() {
  require_cmd oc jq
  local csrs approved skipped
  csrs=$(oc get csr -o json 2>/dev/null || echo '{"items":[]}')
  approved=()
  skipped=()
  while IFS=$'\t' read -r name signer requester; do
    [[ -z "$name" ]] && continue
    case "$signer" in
      kubernetes.io/kube-apiserver-client-kubelet)
        if [[ "$requester" == "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper" \
              || "$requester" == system:node:* ]]; then
          approved+=("$name"); continue
        fi
        ;;
      kubernetes.io/kubelet-serving)
        if [[ "$requester" == system:node:* ]]; then
          approved+=("$name"); continue
        fi
        ;;
    esac
    skipped+=("$name ($signer, $requester)")
  done < <(printf '%s' "$csrs" | jq -r '
      .items[]
      | select((.status // {}) | has("conditions") | not)
      | [.metadata.name, .spec.signerName, .spec.username] | @tsv')
  if (( ${#approved[@]} > 0 )); then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "[dry-run] would approve CSRs: ${approved[*]}"
    else
      log_info "approving CSRs: ${approved[*]}"
      oc adm certificate approve "${approved[@]}" >/dev/null
    fi
  fi
  if (( ${#skipped[@]} > 0 )); then
    for s in "${skipped[@]}"; do log_warn "skipping non-kubelet CSR: $s"; done
  fi
  printf '%s\n' "${#approved[@]}"
}

# --- waiters --------------------------------------------------------------

# Wait until `oc get nodes` succeeds. Returns 0 on success, non-zero on timeout.
wait_for_api() {
  local timeout_min="${1:-$OPERATIONS_TIMEOUT_MIN}"
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  log_info "waiting up to ${timeout_min}m for Kubernetes API to respond..."
  while (( $(date +%s) < deadline )); do
    if oc get nodes >/dev/null 2>&1; then
      log_info "Kubernetes API is reachable"
      return 0
    fi
    sleep 15
  done
  log_err "Kubernetes API did not respond within ${timeout_min} minutes"
  return 1
}

# wait_for_nodes_ready [selector] [timeout_min]
wait_for_nodes_ready() {
  local selector="${1:-}"
  local timeout_min="${2:-$OPERATIONS_TIMEOUT_MIN}"
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  local args=(get nodes -o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")
  log_info "waiting up to ${timeout_min}m for nodes ${selector:-(all)} to become Ready..."
  while (( $(date +%s) < deadline )); do
    local out total ready
    out=$(oc "${args[@]}" 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      total=$(printf '%s' "$out" | jq '.items | length')
      ready=$(printf '%s' "$out" | jq '[.items[] | select((.status.conditions // [])[] | select(.type=="Ready" and .status=="True"))] | length')
      log_info "nodes ${selector:-(all)}: ${ready}/${total} Ready"
      if (( total > 0 && ready == total )); then
        return 0
      fi
    fi
    if [[ "$AUTO_APPROVE_CSRS" == "1" ]]; then
      approve_node_csrs >/dev/null || true
    fi
    sleep 20
  done
  log_err "nodes ${selector:-(all)} did not all become Ready within ${timeout_min} minutes"
  return 1
}

wait_for_cluster_operators() {
  local timeout_min="${1:-$OPERATIONS_TIMEOUT_MIN}"
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  log_info "waiting up to ${timeout_min}m for all clusteroperators to converge..."
  while (( $(date +%s) < deadline )); do
    local raw bad total
    if ! raw=$(oc get co -o json 2>/dev/null); then
      log_info "oc get co not yet responding..."
      sleep 20
      continue
    fi
    total=$(printf '%s' "$raw" | jq '.items | length')
    if (( total == 0 )); then
      log_info "no clusteroperators visible yet..."
      sleep 20
      continue
    fi
    bad=$(printf '%s' "$raw" | jq -r '
      .items[]
      | .metadata.name as $n
      | (.status.conditions // []) as $c
      | ($c[] | select(.type=="Available") | .status) as $av
      | ($c[] | select(.type=="Progressing") | .status) as $pg
      | ($c[] | select(.type=="Degraded") | .status) as $dg
      | select(($av != "True") or ($pg == "True") or ($dg == "True"))
      | $n')
    if [[ -z "$bad" ]]; then
      log_info "all ${total} clusteroperators Available / !Progressing / !Degraded"
      return 0
    fi
    log_info "clusteroperators still converging: $(printf '%s' "$bad" | tr '\n' ' ')"
    sleep 20
  done
  log_warn "some clusteroperators did not converge within ${timeout_min} minutes"
  oc get co || true
  return 1
}

# Quick etcd member health summary. Returns 0 if all members report healthy.
etcd_health() {
  require_cmd oc
  local pod
  pod=$(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    log_warn "no etcd pod available"
    return 1
  fi
  if ! oc -n openshift-etcd rsh -c etcdctl "$pod" \
        etcdctl endpoint health --cluster --write-out=table; then
    log_warn "etcd health check returned non-zero"
    return 1
  fi
}

# Helper: read the value following a flag, raising a clear error if missing.
# Usage: VAL=$(flag_value "--timeout" "${2:-}")
flag_value() {
  local flag="$1" val="${2:-}"
  if [[ -z "$val" || "$val" == --* ]]; then
    log_err "$flag requires a value"
    return 1
  fi
  printf '%s' "$val"
}

# Pre-shutdown sanity checks. Returns non-zero if the cluster doesn't look
# safe to shut down. Callers can opt out via --no-preflight.
preflight_shutdown_checks() {
  require_oc
  log_info "running shutdown preflight checks"
  local masters
  masters=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)
  if (( masters < 3 )); then
    log_err "expected at least 3 control plane nodes, found $masters; refusing graceful shutdown"
    return 1
  fi
  local notready
  notready=$(oc get nodes -l node-role.kubernetes.io/master \
    -o json 2>/dev/null | jq -r '
      .items[]
      | select((.status.conditions // [])[] | select(.type=="Ready" and .status!="True"))
      | .metadata.name' | tr '\n' ' ')
  if [[ -n "$notready" ]]; then
    log_warn "control plane nodes not Ready: $notready"
    log_warn "graceful shutdown of a degraded control plane is risky; consider fixing first"
  fi
  return 0
}

# Wait until every VM matching the given roles is reported as
# stopped or deallocated by Azure. Roles are passed as separate args.
#
# Usage: wait_for_vms_stopped <timeout_min> master worker sriov-worker
# Echoes status updates to stderr. Returns 0 if all reached the target
# state in time, 1 otherwise.
wait_for_vms_stopped() {
  local timeout_min="$1"; shift
  local roles=("$@")
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  local inv bad
  while (( $(date +%s) < deadline )); do
    if ! inv=$(vm_inventory); then
      log_err "lost Azure inventory while waiting for VMs to stop"
      return 1
    fi
    bad=$(printf '%s\n' "$inv" \
      | awk -F'\t' -v roles="${roles[*]}" '
          BEGIN { split(roles, r, " "); for (i in r) want[r[i]] = 1 }
          { if (want[$1] && $3 !~ /[Ss]topped|[Dd]eallocated/) print $2"="$3 }')
    if [[ -z "$bad" ]]; then
      log_info "all target VMs report stopped or deallocated"
      return 0
    fi
    log_info "still waiting: $(printf '%s\n' "$bad" | tr '\n' ' ')"
    sleep 20
  done
  log_err "not all VMs reached stopped state within ${timeout_min} minutes"
  return 1
}

# --- dry-run helper -------------------------------------------------------

run_or_dry() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}
