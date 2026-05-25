locals {
  workload_rg = data.terraform_remote_state.prereqs.outputs.workload_resource_group_name
}

# Legacy managed image bound to the blob
resource "azurerm_image" "rhcos" {
  name                = "img-rhcos-arm64-${var.cluster_name}"
  location            = var.location
  resource_group_name = local.workload_rg
  hyper_v_generation  = "V2"
  tags                = var.tags

  os_disk {
    os_type      = "Linux"
    os_state     = "Generalized"
    blob_uri     = var.rhcos_vhd_url
    caching      = "ReadWrite"
    storage_type = "Standard_LRS"
  }
}

# Shared Image Gallery for arm64 (managed image alone cannot express arch=Arm64)
resource "azurerm_shared_image_gallery" "ocp" {
  name                = replace("sig_ocp_${var.cluster_name}", "-", "_")
  resource_group_name = local.workload_rg
  location            = var.location
  description         = "RHCOS aarch64 images for OpenShift cluster ${var.cluster_name}"
  tags                = var.tags
}

resource "azurerm_shared_image" "rhcos" {
  name                = "rhcos-arm64"
  gallery_name        = azurerm_shared_image_gallery.ocp.name
  resource_group_name = local.workload_rg
  location            = var.location
  os_type             = "Linux"
  architecture        = "Arm64"
  hyper_v_generation  = "V2"
  specialized         = false
  tags                = var.tags

  identifier {
    publisher = "RedHat"
    offer     = "rhcos-arm64"
    sku       = var.cluster_name
  }
}

resource "azurerm_shared_image_version" "rhcos" {
  name                = "0.0.1"
  gallery_name        = azurerm_shared_image_gallery.ocp.name
  image_name          = azurerm_shared_image.rhcos.name
  resource_group_name = local.workload_rg
  location            = var.location
  managed_image_id    = azurerm_image.rhcos.id
  tags                = var.tags

  target_region {
    name                   = var.location
    regional_replica_count = 1
    storage_account_type   = "Standard_LRS"
  }
}
