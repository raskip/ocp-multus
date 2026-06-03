terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}
provider "azurerm" {
  subscription_id = var.cluster_subscription_id
  features {}
}

data "terraform_remote_state" "prereqs" {
  backend = "local"
  config  = { path = "../00-prereqs/terraform.tfstate" }
}
