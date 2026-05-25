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
variable "vm_size" {
  type    = string
  default = "Standard_D4ps_v5"
}
variable "replicas" {
  type    = number
  default = 2
}
variable "sriov_worker_vm_size" {
  description = "VM size for the SR-IOV demo worker. D8ps_v5 has 4 NIC slots and supports MANA Accelerated Networking on ARM."
  type        = string
  default     = "Standard_D8ps_v5"
}
variable "sriov_worker_zone" {
  type    = string
  default = "3"
}
variable "worker_ignition_path" {
  description = "Path to install/worker.ign (produced by 'make ignition')"
  type        = string
  default     = "../../install/worker.ign"
}
variable "worker_ignition" {
  description = "Fallback ignition JSON used when worker_ignition_path does not exist; normal deployments use the generated file."
  type        = string
  default     = "{\"ignition\":{\"version\":\"3.2.0\"}}"
}
variable "ssh_public_key_path" {
  description = "Path to SSH public key for RHCOS VM admin_ssh_key placeholder."
  type        = string
  default     = "../../secrets/id_ed25519.pub"
}
variable "ssh_public_key" {
  description = "Fallback SSH public key used when ssh_public_key_path does not exist; replace in real deployments."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA example@example"
}
variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    workload = "openshift-multus-poc"
    role     = "worker"
  }
}
