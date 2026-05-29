terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "create_bastion" {
  type        = bool
  default     = false
  description = "Explicit opt-in. When false, this example creates no Bastion resources."
}

variable "bastion_subnet_cidr" {
  type        = string
  default     = null
  description = "Must be /26 or larger and not overlap any existing subnet."

  validation {
    condition     = !var.create_bastion || (var.bastion_subnet_cidr != null && can(cidrnetmask(var.bastion_subnet_cidr)))
    error_message = "Set bastion_subnet_cidr to a valid CIDR when create_bastion=true."
  }
}

variable "bastion_host_name" {
  type    = string
  default = "bastion-installer"
}

data "azurerm_virtual_network" "spoke" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_subnet" "bastion" {
  count                = var.create_bastion ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = data.azurerm_virtual_network.spoke.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

resource "azurerm_public_ip" "bastion" {
  count               = var.create_bastion ? 1 : 0
  name                = "${var.bastion_host_name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "this" {
  count               = var.create_bastion ? 1 : 0
  name                = var.bastion_host_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tunneling_enabled   = true

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

output "create_bastion" {
  value = var.create_bastion
}

output "bastion_host_name" {
  value = var.create_bastion ? azurerm_bastion_host.this[0].name : null
}
