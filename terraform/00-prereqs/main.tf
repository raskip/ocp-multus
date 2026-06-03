#-----------------------------------------------------------------------------
# DNS: create public sub-zone and delegate from parent zone
#-----------------------------------------------------------------------------

# Reference the existing parent public DNS zone owned by the customer.
data "azurerm_dns_zone" "parent" {
  provider            = azurerm.dns
  name                = var.parent_dns_zone
  resource_group_name = var.parent_dns_resource_group
}

# New public sub-zone in the same resource group as the parent.
resource "azurerm_dns_zone" "public_subzone" {
  provider            = azurerm.dns
  name                = var.base_domain
  resource_group_name = var.parent_dns_resource_group
  tags                = var.tags
}

# NS delegation record in the parent zone for the OpenShift base domain.
resource "azurerm_dns_ns_record" "delegation" {
  provider            = azurerm.dns
  name                = trimsuffix(trimsuffix(var.base_domain, var.parent_dns_zone), ".")
  zone_name           = data.azurerm_dns_zone.parent.name
  resource_group_name = var.parent_dns_resource_group
  ttl                 = 3600
  records             = azurerm_dns_zone.public_subzone.name_servers
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.base_domain != var.parent_dns_zone && endswith(var.base_domain, ".${var.parent_dns_zone}")
      error_message = "base_domain must be a child sub-zone of parent_dns_zone, for example base_domain=ocp.example.com and parent_dns_zone=example.com."
    }
  }
}

#-----------------------------------------------------------------------------
# Workload resource group and private DNS zone inside the cluster subscription.
#-----------------------------------------------------------------------------
resource "azurerm_resource_group" "workload" {
  provider = azurerm.cluster
  name     = var.workload_resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_virtual_network" "shared" {
  provider            = azurerm.cluster
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group
}

locals {
  # See variable "use_legacy_dns_layout" in variables.tf for the rationale.
  cluster_private_dns_zone_name = var.use_legacy_dns_layout ? var.base_domain : "${var.cluster_name}.${var.base_domain}"
}

resource "azurerm_private_dns_zone" "cluster" {
  provider            = azurerm.cluster
  name                = local.cluster_private_dns_zone_name
  resource_group_name = azurerm_resource_group.workload.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cluster" {
  provider              = azurerm.cluster
  name                  = "pdnslink-${var.cluster_name}"
  resource_group_name   = azurerm_resource_group.workload.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = data.azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = var.tags
}

#-----------------------------------------------------------------------------
# Storage account for ignition + RHCOS VHD, private endpoint only
# Private endpoint is created in Phase 01-network once snet-ocp-master exists,
# so here we only create the account with public network access disabled
# for the blob service.
#-----------------------------------------------------------------------------
resource "random_string" "sa_suffix" {
  length  = 6
  lower   = true
  numeric = true
  upper   = false
  special = false
}

resource "azurerm_storage_account" "ocp" {
  provider                        = azurerm.cluster
  name                            = substr(replace(lower("stocp${var.cluster_name}${random_string.sa_suffix.result}"), "-", ""), 0, 24)
  resource_group_name             = azurerm_resource_group.workload.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = var.tags
}

# Let the current TF principal manage data-plane (create containers, upload blobs, UDK SAS)
data "azurerm_client_config" "current" {
  provider = azurerm.cluster
}

resource "azurerm_role_assignment" "ocp_blob_owner_current" {
  provider             = azurerm.cluster
  scope                = azurerm_storage_account.ocp.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "ignition" {
  provider              = azurerm.cluster
  name                  = "ignition"
  storage_account_id    = azurerm_storage_account.ocp.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "rhcos" {
  provider              = azurerm.cluster
  name                  = "rhcos"
  storage_account_id    = azurerm_storage_account.ocp.id
  container_access_type = "private"
}
