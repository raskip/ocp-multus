terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}
provider "azurerm" {
  subscription_id = var.cluster_subscription_id
  features {
    resource_group { prevent_deletion_if_contains_resources = false }
  }
}

data "terraform_remote_state" "prereqs" {
  backend = "local"
  config  = { path = "../00-prereqs/terraform.tfstate" }
}
data "terraform_remote_state" "network" {
  backend = "local"
  config  = { path = "../01-network/terraform.tfstate" }
}
data "terraform_remote_state" "image" {
  backend = "local"
  config  = { path = "../02-image/terraform.tfstate" }
}
