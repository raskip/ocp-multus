#!/usr/bin/env bash
# Render per-stack from-env.auto.tfvars files for every Terraform stack from
# config/cluster.env. This generalises scripts/render-tfvars.sh (which only
# emits architecture + VM sizes) so the customer maintains a single source
# of truth in cluster.env instead of editing six per-stack terraform.tfvars.
#
# Backward compat:
#   - If a stack already has a hand-edited terraform.tfvars, this script does
#     NOT touch it. The generated *.auto.tfvars overrides matching keys per
#     Terraform precedence (auto-loaded *.auto.tfvars take precedence over
#     terraform.tfvars). Set keys only in terraform.tfvars to override
#     individual generated values back.
#   - Only fields explicitly listed below are rendered. Stage-output fields
#     (rhcos_vhd_url, ignition pointers, master/worker ignition paths) are
#     still written by their existing upload-*.sh scripts as before.
#
# infra_id handling:
#   1. If install/metadata.json exists, its .infraID wins (canonical).
#   2. Else if $INFRA_ID is set in cluster.env, use it.
#   3. Else default to ${CLUSTER_NAME}-poc (deterministic placeholder).
#   Re-run this script after `make ignition` to pick up the canonical value.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/cluster.env}"

[[ -f "$CONFIG_FILE" ]] || {
  echo "missing $CONFIG_FILE" >&2
  echo "Run 'make init-config' or copy config/cluster.example.env first." >&2
  exit 1
}

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

require() {
  local var="$1"
  [[ -n "${!var:-}" ]] || { echo "missing required cluster.env value: $var" >&2; exit 1; }
}

# Minimum required for the static fields rendered below.
require CLUSTER_NAME
require BASE_DOMAIN
require LOCATION
require WORKLOAD_RESOURCE_GROUP
require VIRTUAL_NETWORK
require NETWORK_RESOURCE_GROUP
# Public DNS is opt-in (CREATE_PUBLIC_DNS, default false = internal-only). The
# parent public zone vars are only required when the repo creates the public
# sub-zone + NS delegation. See docs/dns-internal-only.md.
: "${CREATE_PUBLIC_DNS:=false}"
if [[ "$CREATE_PUBLIC_DNS" == "true" ]]; then
  require PARENT_DNS_ZONE
  require PARENT_DNS_RESOURCE_GROUP
fi
# Default to empty when internal-only so the heredoc below stays safe under
# `set -u`; the gated Terraform resources are not created, so the values are
# unused.
: "${PARENT_DNS_ZONE:=}"
: "${PARENT_DNS_RESOURCE_GROUP:=}"
require ADMIN_SSH_SOURCE_IP
require ARCHITECTURE

# Subscription IDs: default the DNS ones to the cluster sub when unset.
: "${CLUSTER_SUBSCRIPTION_ID:?CLUSTER_SUBSCRIPTION_ID not set in $CONFIG_FILE}"
: "${DNS_SUBSCRIPTION_ID:=$CLUSTER_SUBSCRIPTION_ID}"
: "${PRIVATE_DNS_SUBSCRIPTION_ID:=$CLUSTER_SUBSCRIPTION_ID}"
: "${HUB_DNS_RESOURCE_GROUP:=$NETWORK_RESOURCE_GROUP}"

# Subnet CIDRs default to the values that have always shipped in
# 01-network/variables.tf so existing customers see no change.
: "${SUBNET_MASTER_CIDR:=10.20.1.0/28}"
: "${SUBNET_WORKER_CIDR:=10.20.1.16/28}"
: "${SUBNET_BOOTSTRAP_CIDR:=10.20.1.32/28}"
: "${SUBNET_MULTUS_CIDR:=10.20.2.0/23}"
: "${SUBNET_SRIOV_CIDR:=10.20.7.0/24}"

# Optional CNF profile (default OFF). CNF_PROFILE toggles enable_cnf_lans in the
# 01-network and 05-workers stacks; the 3 LAN CIDRs default to placeholders.
: "${CNF_PROFILE:=false}"
# SR-IOV demo worker is opt-in (default OFF). ENABLE_SRIOV gates enable_sriov in
# 01-network (snet-ocp-sriov subnet) and 05-workers (SR-IOV demo worker VM).
: "${ENABLE_SRIOV:=false}"
: "${SUBNET_OAM_CIDR:=10.20.4.0/28}"
: "${SUBNET_AUSFUDM_CIDR:=10.20.5.0/26}"
: "${SUBNET_HSSHLR_CIDR:=10.20.6.0/26}"

# Default to attaching the cluster route table to the master/bootstrap/multus
# subnets in addition to worker (worker is always attached). This is the right
# default for hub-spoke + firewall-egress topologies, which is the recommended
# enterprise setup (see docs/network-prereqs.md). Customers who use NAT
# gateway or direct internet on master subnets can set
# ATTACH_RT_EXTRA_SUBNETS= (empty) in config/cluster.env to restore the
# legacy behavior where only worker subnet has the UDR attached.
: "${ATTACH_RT_EXTRA_SUBNETS:=master,bootstrap,multus}"

# B62 fix: default the new DNS layout (zone is ${CLUSTER_NAME}.${BASE_DOMAIN},
# records use short names). Set USE_LEGACY_DNS_LAYOUT=true in cluster.env only
# if you have an existing pre-fix cluster you cannot migrate.
: "${USE_LEGACY_DNS_LAYOUT:=false}"
: "${CREATE_WINDOWS_JUMP:=false}"
: "${CREATE_LINUX_BASTION:=false}"

# Resolve infra_id (precedence: metadata.json > $INFRA_ID > ${CLUSTER_NAME}-poc).
INFRA_ID_FROM_ENV="${INFRA_ID:-}"
META="$REPO_ROOT/install/metadata.json"
META_INFRA=""
if [[ -f "$META" ]] && command -v jq >/dev/null 2>&1; then
  META_INFRA="$(jq -r '.infraID // empty' "$META" 2>/dev/null || true)"
fi
INFRA_ID="${META_INFRA:-${INFRA_ID_FROM_ENV:-${CLUSTER_NAME}-poc}}"

# Helper: HCL-escape an arbitrary string for a tfvars `key = "value"` line.
hcl_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

write_file() {
  local target="$1"
  local body="$2"
  mkdir -p "$(dirname "$target")"
  {
    printf '# Generated by scripts/render-tfvars-from-env.sh from config/cluster.env.\n'
    printf '# Do not edit by hand; edit config/cluster.env and re-run `make tfvars`.\n'
    printf '# *.auto.tfvars overrides terraform.tfvars per Terraform precedence.\n'
    printf '%s\n' "$body"
  } > "$target"
  echo "Wrote ${target#$REPO_ROOT/}"
}

# ---- 00-prereqs ------------------------------------------------------------
write_file "$REPO_ROOT/terraform/00-prereqs/from-env.auto.tfvars" "$(cat <<EOF
cluster_subscription_id      = $(hcl_str "$CLUSTER_SUBSCRIPTION_ID")
dns_subscription_id          = $(hcl_str "$DNS_SUBSCRIPTION_ID")
location                     = $(hcl_str "$LOCATION")
cluster_name                 = $(hcl_str "$CLUSTER_NAME")
base_domain                  = $(hcl_str "$BASE_DOMAIN")
parent_dns_zone              = $(hcl_str "$PARENT_DNS_ZONE")
parent_dns_resource_group    = $(hcl_str "$PARENT_DNS_RESOURCE_GROUP")
workload_resource_group_name = $(hcl_str "$WORKLOAD_RESOURCE_GROUP")
vnet_name                    = $(hcl_str "$VIRTUAL_NETWORK")
vnet_resource_group          = $(hcl_str "$NETWORK_RESOURCE_GROUP")
create_public_dns            = $CREATE_PUBLIC_DNS
use_legacy_dns_layout        = $USE_LEGACY_DNS_LAYOUT
EOF
)"

# ---- 01-network ------------------------------------------------------------
# Convert comma-separated ATTACH_RT_EXTRA_SUBNETS into an HCL list literal.
# Empty value -> [] (legacy behavior: only worker has UDR).
hcl_string_list() {
  local csv="$1"
  if [[ -z "$csv" ]]; then printf '[]'; return; fi
  local IFS=','
  read -ra parts <<< "$csv"
  local out="["
  local sep=""
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -z "$p" ]] && continue
    out+="${sep}\"${p}\""
    sep=", "
  done
  out+="]"
  printf '%s' "$out"
}

write_file "$REPO_ROOT/terraform/01-network/from-env.auto.tfvars" "$(cat <<EOF
cluster_subscription_id      = $(hcl_str "$CLUSTER_SUBSCRIPTION_ID")
private_dns_subscription_id  = $(hcl_str "$PRIVATE_DNS_SUBSCRIPTION_ID")
hub_dns_resource_group       = $(hcl_str "$HUB_DNS_RESOURCE_GROUP")
location                     = $(hcl_str "$LOCATION")
cluster_name                 = $(hcl_str "$CLUSTER_NAME")
infra_id                     = $(hcl_str "$INFRA_ID")
vnet_name                    = $(hcl_str "$VIRTUAL_NETWORK")
vnet_resource_group          = $(hcl_str "$NETWORK_RESOURCE_GROUP")
workload_resource_group_name = $(hcl_str "$WORKLOAD_RESOURCE_GROUP")
private_dns_zone_name        = $(hcl_str "$BASE_DOMAIN")
use_legacy_dns_layout        = $USE_LEGACY_DNS_LAYOUT
admin_ssh_source_ip          = $(hcl_str "$ADMIN_SSH_SOURCE_IP")
create_windows_jump          = $CREATE_WINDOWS_JUMP
create_linux_bastion         = $CREATE_LINUX_BASTION
subnet_master_cidr           = $(hcl_str "$SUBNET_MASTER_CIDR")
subnet_worker_cidr           = $(hcl_str "$SUBNET_WORKER_CIDR")
subnet_bootstrap_cidr        = $(hcl_str "$SUBNET_BOOTSTRAP_CIDR")
subnet_multus_cidr           = $(hcl_str "$SUBNET_MULTUS_CIDR")
subnet_sriov_cidr            = $(hcl_str "$SUBNET_SRIOV_CIDR")
enable_cnf_lans              = $CNF_PROFILE
enable_sriov                 = $ENABLE_SRIOV
subnet_oam_cidr              = $(hcl_str "$SUBNET_OAM_CIDR")
subnet_ausfudm_cidr          = $(hcl_str "$SUBNET_AUSFUDM_CIDR")
subnet_hsshlr_cidr           = $(hcl_str "$SUBNET_HSSHLR_CIDR")
attach_route_table_to_extra_subnets = $(hcl_string_list "$ATTACH_RT_EXTRA_SUBNETS")
EOF
)"

# ---- 02-image / 03-bootstrap / 04-control-plane / 05-workers ---------------
# These stacks only need cluster_subscription_id, location, cluster_name from
# cluster.env (other variables come from stage-output upload scripts or
# render-tfvars.sh).
for STACK in 02-image 03-bootstrap 04-control-plane 05-workers; do
  write_file "$REPO_ROOT/terraform/$STACK/from-env.auto.tfvars" "$(cat <<EOF
cluster_subscription_id = $(hcl_str "$CLUSTER_SUBSCRIPTION_ID")
location                = $(hcl_str "$LOCATION")
cluster_name            = $(hcl_str "$CLUSTER_NAME")
EOF
)"
done

# 03/04/05 also need ssh_public_key_path (relative to each stack dir).
# Honour SSH_PUBLIC_KEY_FILE override from cluster.env; default matches the
# 03-bootstrap/04-control-plane/05-workers tfvars defaults.
SSH_PUB_REL="${SSH_PUBLIC_KEY_FILE:-secrets/id_ed25519.pub}"
for STACK in 03-bootstrap 04-control-plane 05-workers; do
  printf '%s\n' "ssh_public_key_path = \"../../${SSH_PUB_REL}\"" \
    >> "$REPO_ROOT/terraform/$STACK/from-env.auto.tfvars"
done

# CNF profile toggle for the workers stack (must match 01-network/enable_cnf_lans).
printf '%s\n' "enable_cnf_lans = $CNF_PROFILE" \
  >> "$REPO_ROOT/terraform/05-workers/from-env.auto.tfvars"

# SR-IOV worker toggle for the workers stack (must match 01-network/enable_sriov).
printf '%s\n' "enable_sriov = $ENABLE_SRIOV" \
  >> "$REPO_ROOT/terraform/05-workers/from-env.auto.tfvars"

if [[ -n "${META_INFRA:-}" ]]; then
  echo "infra_id resolved from install/metadata.json: $INFRA_ID"
elif [[ -n "$INFRA_ID_FROM_ENV" ]]; then
  echo "infra_id taken from config/cluster.env: $INFRA_ID"
else
  echo "infra_id defaulted to '$INFRA_ID' (no install/metadata.json yet)."
  echo "Re-run 'make tfvars' after 'make ignition' to pick up the canonical value."
fi
