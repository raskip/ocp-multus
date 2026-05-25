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
  description = "Blob URL of the uploaded RHCOS aarch64 VHD (written by scripts/upload-rhcos.sh)"
  type        = string
}
variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    workload = "openshift-multus-poc"
  }
}
