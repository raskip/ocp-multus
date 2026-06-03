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
  alias           = "spoke"
  subscription_id = var.subscription_id
  features {}
}

provider "azurerm" {
  alias           = "hub"
  subscription_id = var.hub_subscription_id
  features {}
}

variable "subscription_id" {
  type = string
}

variable "hub_subscription_id" {
  type = string
}

variable "location" {
  type = string
}

variable "hub_firewall_policy_id" {
  type = string
}

variable "hub_firewall_public_ip" {
  type = string
}

variable "hub_firewall_private_ip" {
  type        = string
  description = "Private IP of the hub firewall (next-hop for UDR)."
}

variable "spoke_resource_group" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "jump_subnet_name" {
  type = string
}

variable "jump_vm_private_ip" {
  type = string
}

variable "admin_workstation_cidr" {
  type        = string
  description = "Workstation public IP (e.g. 203.0.113.10/32)."
}

variable "dnat_external_port" {
  type    = number
  default = 2222
}

variable "rule_collection_group_name" {
  type    = string
  default = "rcg-jump-host-access"
}

variable "rule_collection_group_priority" {
  type    = number
  default = 200
}

variable "api_lb_private_ip" {
  type        = string
  default     = ""
  description = "If non-empty, also DNATs <firewall_public_ip>:6443 to <api_lb_private_ip>:6443."
}

# ---- Hub firewall DNAT rule -------------------------------------------------
resource "azurerm_firewall_policy_rule_collection_group" "jump_access" {
  provider           = azurerm.hub
  name               = var.rule_collection_group_name
  firewall_policy_id = var.hub_firewall_policy_id
  priority           = var.rule_collection_group_priority

  nat_rule_collection {
    name     = "jump-host-dnat"
    priority = 100
    action   = "Dnat"

    rule {
      name                = "ssh-to-jump"
      protocols           = ["TCP"]
      source_addresses    = [var.admin_workstation_cidr]
      destination_address = var.hub_firewall_public_ip
      destination_ports   = [tostring(var.dnat_external_port)]
      translated_address  = var.jump_vm_private_ip
      translated_port     = "22"
    }

    dynamic "rule" {
      for_each = var.api_lb_private_ip == "" ? [] : [1]
      content {
        name                = "https-to-api-lb"
        protocols           = ["TCP"]
        source_addresses    = [var.admin_workstation_cidr]
        destination_address = var.hub_firewall_public_ip
        destination_ports   = ["6443"]
        translated_address  = var.api_lb_private_ip
        translated_port     = "6443"
      }
    }
  }
}

# ---- UDR on the jump subnet so reply traffic returns via the firewall -------
resource "azurerm_route_table" "jump_via_fw" {
  provider            = azurerm.spoke
  name                = "rt-jump-via-fw"
  resource_group_name = var.spoke_resource_group
  location            = var.location
}

resource "azurerm_route" "default_to_fw" {
  provider               = azurerm.spoke
  name                   = "default-egress-fw"
  resource_group_name    = var.spoke_resource_group
  route_table_name       = azurerm_route_table.jump_via_fw.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.hub_firewall_private_ip
}

data "azurerm_subnet" "jump" {
  provider             = azurerm.spoke
  name                 = var.jump_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.spoke_resource_group
}

resource "azurerm_subnet_route_table_association" "jump" {
  provider       = azurerm.spoke
  subnet_id      = data.azurerm_subnet.jump.id
  route_table_id = azurerm_route_table.jump_via_fw.id
}

output "ssh_command" {
  value = "ssh -p ${var.dnat_external_port} <user>@${var.hub_firewall_public_ip}"
}

output "etc_hosts_line" {
  description = "Add this to /etc/hosts on your workstation so `oc` resolves the cluster API to the firewall."
  value       = var.api_lb_private_ip == "" ? "" : "${var.hub_firewall_public_ip} api.<cluster>.<base_domain>"
}
