terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.cluster_subscription_id
  features {}
}

provider "azurerm" {
  alias           = "private_dns"
  subscription_id = var.private_dns_subscription_id
  features {}
}

provider "azapi" {
  subscription_id = var.cluster_subscription_id
}
