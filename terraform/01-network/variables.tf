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

variable "private_dns_zone_name" {
  type    = string
  default = "ocp.example.com"
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
