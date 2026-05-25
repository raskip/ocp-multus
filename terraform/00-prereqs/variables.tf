variable "cluster_subscription_id" {
  description = "Azure subscription where the OpenShift cluster resources are deployed."
  type        = string
}

variable "dns_subscription_id" {
  description = "Azure subscription hosting the parent public DNS zone."
  type        = string
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "cluster_name" {
  type    = string
  default = "lab"
}

variable "base_domain" {
  type    = string
  default = "ocp.example.com"
}

variable "parent_dns_zone" {
  type    = string
  default = "example.com"
}

variable "parent_dns_resource_group" {
  type    = string
  default = "rg-dns-public-example"
}

variable "workload_resource_group_name" {
  type    = string
  default = "rg-ocp-lab"
}

variable "vnet_name" {
  type    = string
  default = "vnet-ocp-example"
}

variable "vnet_resource_group" {
  type    = string
  default = "rg-network-example"
}

variable "tags" {
  type = map(string)
  default = {
    project  = "ocp-lab"
    owner    = "platform-team"
    workload = "openshift-multus-poc"
  }
}
