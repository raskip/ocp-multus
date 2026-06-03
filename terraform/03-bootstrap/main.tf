locals {
  workload_rg         = data.terraform_remote_state.prereqs.outputs.workload_resource_group_name
  subnet_bootstrap_id = data.terraform_remote_state.network.outputs.subnet_bootstrap_id
  api_backend_pool_id = data.terraform_remote_state.network.outputs.api_internal_backend_pool_id
  image_id            = data.terraform_remote_state.image.outputs.image_id
  ssh_public_key_path = abspath("${path.root}/${var.ssh_public_key_path}")
  ssh_pub             = fileexists(local.ssh_public_key_path) ? file(local.ssh_public_key_path) : var.ssh_public_key
}

resource "azurerm_network_interface" "bootstrap" {
  name                = "nic-bootstrap-${var.cluster_name}"
  location            = var.location
  resource_group_name = local.workload_rg
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.subnet_bootstrap_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "bootstrap_api" {
  network_interface_id    = azurerm_network_interface.bootstrap.id
  ip_configuration_name   = "primary"
  backend_address_pool_id = local.api_backend_pool_id
}

resource "azurerm_linux_virtual_machine" "bootstrap" {
  name                            = "vm-bootstrap-${var.cluster_name}"
  location                        = var.location
  resource_group_name             = local.workload_rg
  size                            = var.vm_size
  admin_username                  = "core"
  network_interface_ids           = [azurerm_network_interface.bootstrap.id]
  source_image_id                 = local.image_id
  disable_password_authentication = true
  custom_data                     = base64encode(var.bootstrap_ignition_pointer)
  tags                            = var.tags

  # RHCOS provisions via ignition; the SSH key here is a placeholder so the
  # provider accepts the config. Real SSH access is granted by the sshKey in
  # install-config.yaml, which is baked into every ignition config.
  admin_ssh_key {
    username   = "core"
    public_key = local.ssh_pub
  }

  os_disk {
    name                 = "osdisk-bootstrap-${var.cluster_name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  boot_diagnostics {}
}
