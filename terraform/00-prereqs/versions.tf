terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Cluster workload subscription
provider "azurerm" {
  alias               = "cluster"
  subscription_id     = var.cluster_subscription_id
  storage_use_azuread = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Subscription that owns the parent public DNS zone
provider "azurerm" {
  alias           = "dns"
  subscription_id = var.dns_subscription_id
  features {}
}
