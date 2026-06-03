locals {
  workload_rg         = data.terraform_remote_state.prereqs.outputs.workload_resource_group_name
  subnet_master_id    = data.terraform_remote_state.network.outputs.subnet_master_id
  api_backend_pool_id = data.terraform_remote_state.network.outputs.api_internal_backend_pool_id
  image_id            = data.terraform_remote_state.image.outputs.image_id

  master_ignition_path = abspath("${path.root}/${var.master_ignition_path}")
  master_ignition      = fileexists(local.master_ignition_path) ? file(local.master_ignition_path) : var.master_ignition
  ssh_public_key_path  = abspath("${path.root}/${var.ssh_public_key_path}")
  ssh_pub              = fileexists(local.ssh_public_key_path) ? file(local.ssh_public_key_path) : var.ssh_public_key
  zones                = ["3", "3", "3"]
}

resource "azurerm_network_interface" "master" {
  count               = var.replicas
  name                = "nic-master-${count.index}-${var.cluster_name}"
  location            = var.location
  resource_group_name = local.workload_rg
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.subnet_master_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "master_api" {
  count                   = var.replicas
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "primary"
  backend_address_pool_id = local.api_backend_pool_id
}

resource "azurerm_linux_virtual_machine" "master" {
  count                           = var.replicas
  name                            = "vm-master-${count.index}-${var.cluster_name}"
  location                        = var.location
  resource_group_name             = local.workload_rg
  size                            = var.vm_size
  zone                            = element(local.zones, count.index)
  admin_username                  = "core"
  network_interface_ids           = [azurerm_network_interface.master[count.index].id]
  source_image_id                 = local.image_id
  disable_password_authentication = true
  custom_data                     = base64encode(local.master_ignition)
  tags                            = var.tags

  admin_ssh_key {
    username   = "core"
    public_key = local.ssh_pub
  }

  os_disk {
    name                 = "osdisk-master-${count.index}-${var.cluster_name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  boot_diagnostics {}
}
