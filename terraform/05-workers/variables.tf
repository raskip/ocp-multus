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
  default = "Standard_D4s_v5"
}
variable "replicas" {
  type    = number
  default = 2
}
variable "enable_cnf_lans" {
  description = "When true, give each worker a dedicated NIC on each CNF LAN (OAM/AUSF-UDM/HSS-HLR) with Accelerated Networking and drop the demo multus NIC. Must match enable_cnf_lans in 01-network. Requires a 4-NIC SKU such as Standard_D8s_v5. Default false."
  type        = bool
  default     = false
}
variable "enable_sriov" {
  description = "When true, create the SR-IOV demo worker VM and its NICs. Must match enable_sriov in 01-network (which creates the snet-ocp-sriov subnet). Default false."
  type        = bool
  default     = false
}
variable "sriov_worker_vm_size" {
  description = "VM size for the SR-IOV demo worker. Only used when enable_sriov = true. D8s_v5 (x86_64) and D8ps_v5 (arm64) both have 4 NIC slots and support Accelerated Networking."
  type        = string
  default     = "Standard_D8s_v5"
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
