variable "cluster_subscription_id" {
  type = string
}

variable "private_dns_subscription_id" {
  description = "Subscription containing the privatelink.blob.core.windows.net private DNS zone."
  type        = string
}

variable "hub_dns_resource_group" {
  description = "Resource group containing the privatelink.blob.core.windows.net private DNS zone."
  type        = string
  default     = "rg-private-dns-example"
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "cluster_name" {
  type    = string
  default = "lab"
}

variable "infra_id" {
  type        = string
  description = "OpenShift infraID from install/metadata.json. Used to name resources that the Azure cloud provider mutates."
}

variable "vnet_name" {
  type    = string
  default = "vnet-ocp-example"
}

variable "vnet_resource_group" {
  type    = string
  default = "rg-network-example"
}

variable "workload_resource_group_name" {
  type    = string
  default = "rg-ocp-lab"
}

variable "subnet_master_cidr" {
  type    = string
  default = "10.20.1.0/28"
}

variable "subnet_worker_cidr" {
  type    = string
  default = "10.20.1.16/28"
}

variable "subnet_bootstrap_cidr" {
  type    = string
  default = "10.20.1.32/28"
}

variable "subnet_multus_cidr" {
  type    = string
  default = "10.20.2.0/24"
}

variable "subnet_sriov_cidr" {
  type    = string
  default = "10.20.3.0/24"
}

#-----------------------------------------------------------------------------
# BYO-network mode (opt-in)
#
# When manage_network_resources = true (default), this stack creates the
# NSGs, named subnets, and the cluster route table. This is the original
# behavior and is unchanged for existing users.
#
# When manage_network_resources = false, this stack does NOT create any
# NSG / subnet / route table — the customer's network team is expected
# to have provisioned them ahead of time (with their own tooling: Bicep,
# Terraform, az CLI, ARM, Ansible). The stack then data-looks-up the
# pre-existing resources using the *_id inputs below.
#
# Either way, the cluster-specific resources (internal LBs, DNS records,
# storage Private Endpoint, uploader VM, Windows jump VM) are always
# created — those belong to the cluster, not to shared network plumbing.
#
# See docs/network-prereqs.md for the BYO contract (subnets, NSGs, UDR,
# DNS, peering) and examples/network-prereqs-azcli/ for runnable
# scripts a network team can adapt.
#-----------------------------------------------------------------------------
variable "manage_network_resources" {
  description = "When true (default), this stack creates NSGs, subnets, and the route table. When false, the stack data-looks-up pre-existing resources via the *_id inputs (BYO-network mode)."
  type        = bool
  default     = true
}

variable "subnet_master_id" {
  description = "BYO-network only: full Resource ID of the pre-existing master subnet. Required when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "subnet_worker_id" {
  description = "BYO-network only: full Resource ID of the pre-existing worker subnet. Required when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "subnet_bootstrap_id" {
  description = "BYO-network only: full Resource ID of the pre-existing bootstrap subnet. Required when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "subnet_multus_id" {
  description = "BYO-network only: full Resource ID of the pre-existing multus subnet. Required when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "subnet_sriov_id" {
  description = "BYO-network only: full Resource ID of the pre-existing sriov subnet. Required when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "nsg_master_id" {
  description = "BYO-network only: full Resource ID of the NSG attached to the master subnet. Optional informational input — not referenced when manage_network_resources = false (the NSG is already attached to the subnet)."
  type        = string
  default     = ""
}

variable "nsg_worker_id" {
  description = "BYO-network only: full Resource ID of the NSG attached to the worker subnet. Optional informational input — not referenced when manage_network_resources = false."
  type        = string
  default     = ""
}

variable "route_table_id" {
  description = "BYO-network only: full Resource ID of the pre-existing route table that the cluster cloud-provider will mutate. Required when manage_network_resources = false (the cloud provider's identity needs Network Contributor on this scope)."
  type        = string
  default     = ""
}

variable "attach_route_table_to_extra_subnets" {
  description = "Repo-managed mode only: extra subnet roles (besides worker) to attach the cluster route table to. Recommended for hub-spoke + firewall egress: [\"master\", \"bootstrap\", \"multus\"]. Default is empty for backward compat (only worker is attached, matching the historical behavior)."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for s in var.attach_route_table_to_extra_subnets :
      contains(["master", "bootstrap", "multus", "sriov"], s)
    ])
    error_message = "attach_route_table_to_extra_subnets entries must be a subset of: master, bootstrap, multus, sriov."
  }
}

variable "private_dns_zone_name" {
  description = "Base domain (must match var.base_domain from 00-prereqs). The actual private DNS zone name is computed as either this value (legacy layout) or '$${cluster_name}.$${this}' (default). The variable name is retained for backward compat with existing tfvars files."
  type        = string
  default     = "ocp.example.com"
}

# B62 fix: see terraform/00-prereqs/variables.tf for full rationale.
# This MUST match the same flag in 00-prereqs or the zone name + records
# will not line up. Default false (new layout: zone is
# ${cluster_name}.${private_dns_zone_name}, records use short names).
variable "use_legacy_dns_layout" {
  description = "When false (default), records are written into zone $${cluster_name}.$${private_dns_zone_name} using short names (api, api-int, *.apps). Set to true ONLY for legacy installs created before the B62 fix."
  type        = bool
  default     = false
}

variable "storage_account_name" {
  description = "Storage account from 00-prereqs (unused — resolved via remote_state; kept for backwards compat)"
  type        = string
  default     = ""
}

variable "storage_account_id" {
  description = "Unused — resolved via remote_state"
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for uploader jumpbox (reused by cluster nodes)"
  type        = string
  default     = "../../secrets/id_ed25519.pub"
}

variable "admin_ssh_source_ip" {
  description = "Public IP (or CIDR) allowed to SSH to the uploader jumpbox"
  type        = string
}

variable "architecture" {
  description = "Cluster CPU architecture: x86_64 (default, Intel D*s_v5) or arm64 (Ampere D*ps_v5)."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be one of: x86_64, arm64."
  }
}

variable "uploader_vm_size" {
  description = "Override for the uploader VM size. Empty string uses the per-architecture default (D2s_v5 / D2ps_v5)."
  type        = string
  default     = ""
}

variable "uploader_image_sku" {
  description = "Override for the uploader Ubuntu 24.04 SKU. Empty string uses the per-architecture default (server / server-arm64)."
  type        = string
  default     = ""
}

variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    workload = "openshift-multus-poc"
  }
}
