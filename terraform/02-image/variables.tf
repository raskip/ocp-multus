variable "cluster_subscription_id" {
  type = string
}
variable "location" {
  type    = string
  default = "northeurope"
}
variable "cluster_name" {
  type    = string
  default = "lab"
}
variable "rhcos_vhd_url" {
  description = "Blob URL of the uploaded RHCOS VHD (written by scripts/upload-rhcos.sh)"
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
variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    workload = "openshift-multus-poc"
  }
}
