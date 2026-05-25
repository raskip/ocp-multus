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
variable "bootstrap_ignition_pointer" {
  description = "Ignition JSON that redirects to bootstrap.ign in blob (written by scripts/upload-ignition.sh)"
  type        = string
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
    role     = "bootstrap"
  }
}
