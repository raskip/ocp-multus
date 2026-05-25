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
  default = "Standard_D8ps_v5"
}
variable "replicas" {
  type    = number
  default = 3
}
variable "master_ignition_path" {
  description = "Path to install/master.ign (produced by 'make ignition')"
  type        = string
  default     = "../../install/master.ign"
}
variable "master_ignition" {
  description = "Fallback ignition JSON used when master_ignition_path does not exist; normal deployments use the generated file."
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
    role     = "master"
  }
}
