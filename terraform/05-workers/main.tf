locals {
  workload_rg             = data.terraform_remote_state.prereqs.outputs.workload_resource_group_name
  subnet_worker_id        = data.terraform_remote_state.network.outputs.subnet_worker_id
  subnet_multus_id        = data.terraform_remote_state.network.outputs.subnet_multus_id
  subnet_sriov_id         = data.terraform_remote_state.network.outputs.subnet_sriov_id
  subnet_oam_id           = data.terraform_remote_state.network.outputs.subnet_oam_id
  subnet_ausfudm_id       = data.terraform_remote_state.network.outputs.subnet_ausfudm_id
  subnet_hsshlr_id        = data.terraform_remote_state.network.outputs.subnet_hsshlr_id
  ingress_backend_pool_id = data.terraform_remote_state.network.outputs.ingress_internal_backend_pool_id
  image_id                = data.terraform_remote_state.image.outputs.image_id

  worker_ignition_path = abspath("${path.root}/${var.worker_ignition_path}")
  worker_ignition      = fileexists(local.worker_ignition_path) ? file(local.worker_ignition_path) : var.worker_ignition
  ssh_public_key_path  = abspath("${path.root}/${var.ssh_public_key_path}")
  ssh_pub              = fileexists(local.ssh_public_key_path) ? file(local.ssh_public_key_path) : var.ssh_public_key
  zones                = ["3", "3", "3"]
}

# Primary NIC: worker subnet, attached to ingress LB backend
resource "azurerm_network_interface" "worker_primary" {
  count                          = var.replicas
  name                           = "nic-worker-${count.index}-primary-${var.cluster_name}"
  location                       = var.location
  resource_group_name            = local.workload_rg
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = var.enable_cnf_lans
  tags                           = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.subnet_worker_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "worker_ingress" {
  count                   = var.replicas
  network_interface_id    = azurerm_network_interface.worker_primary[count.index].id
  ip_configuration_name   = "primary"
  backend_address_pool_id = local.ingress_backend_pool_id
}

# Secondary NIC: Multus subnet. No LB, IP forwarding on so macvlan-ed pods can
# send packets with their own IPs/MACs out through this NIC.
# In CNF mode (enable_cnf_lans=true) this demo NIC is dropped in favour of the
# three dedicated CNF LAN NICs below, keeping the worker at 4 NICs (D8s_v5).
resource "azurerm_network_interface" "worker_multus" {
  count                 = var.enable_cnf_lans ? 0 : var.replicas
  name                  = "nic-worker-${count.index}-multus-${var.cluster_name}"
  location              = var.location
  resource_group_name   = local.workload_rg
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "multus"
    subnet_id                     = local.subnet_multus_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

#-----------------------------------------------------------------------------
# CNF LAN NICs (one per worker per LAN: OAM + AUSF-UDM + HSS-HLR). Created only
# in CNF mode. Accelerated Networking ON for the 400 MB/s TCP/UDP target (AN
# does not accelerate SCTP — see docs/cnf-telco-profile.md). IP forwarding ON so
# ipvlan/macvlan-ed pods can send with their own IPs out through the NIC.
#-----------------------------------------------------------------------------
resource "azurerm_network_interface" "worker_oam" {
  count                          = var.enable_cnf_lans ? var.replicas : 0
  name                           = "nic-worker-${count.index}-oam-${var.cluster_name}"
  location                       = var.location
  resource_group_name            = local.workload_rg
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "oam"
    subnet_id                     = local.subnet_oam_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface" "worker_ausfudm" {
  count                          = var.enable_cnf_lans ? var.replicas : 0
  name                           = "nic-worker-${count.index}-ausfudm-${var.cluster_name}"
  location                       = var.location
  resource_group_name            = local.workload_rg
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ausfudm"
    subnet_id                     = local.subnet_ausfudm_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface" "worker_hsshlr" {
  count                          = var.enable_cnf_lans ? var.replicas : 0
  name                           = "nic-worker-${count.index}-hsshlr-${var.cluster_name}"
  location                       = var.location
  resource_group_name            = local.workload_rg
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "hsshlr"
    subnet_id                     = local.subnet_hsshlr_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_linux_virtual_machine" "worker" {
  count               = var.replicas
  name                = "vm-worker-${count.index}-${var.cluster_name}"
  location            = var.location
  resource_group_name = local.workload_rg
  size                = var.vm_size
  zone                = element(local.zones, count.index)
  admin_username      = "core"
  network_interface_ids = concat(
    [azurerm_network_interface.worker_primary[count.index].id],
    var.enable_cnf_lans ? [
      azurerm_network_interface.worker_oam[count.index].id,
      azurerm_network_interface.worker_ausfudm[count.index].id,
      azurerm_network_interface.worker_hsshlr[count.index].id,
      ] : [
      azurerm_network_interface.worker_multus[count.index].id,
    ],
  )
  source_image_id                 = local.image_id
  disable_password_authentication = true
  custom_data                     = base64encode(local.worker_ignition)
  tags                            = var.tags

  admin_ssh_key {
    username   = "core"
    public_key = local.ssh_pub
  }

  os_disk {
    name                 = "osdisk-worker-${count.index}-${var.cluster_name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  boot_diagnostics {}
}

#-----------------------------------------------------------------------------
# SR-IOV demo worker (single, larger SKU, 3 NICs, AN-enabled SR-IOV NIC)
#
# Separate from the count-based workers above so the existing pair stays on
# the default worker SKU (D4s_v5 / D4ps_v5, 2 NIC slots) untouched.
#-----------------------------------------------------------------------------
resource "azurerm_network_interface" "sriov_worker_primary" {
  name                  = "nic-worker-sriov-primary-${var.cluster_name}"
  location              = var.location
  resource_group_name   = local.workload_rg
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.subnet_worker_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "sriov_worker_ingress" {
  network_interface_id    = azurerm_network_interface.sriov_worker_primary.id
  ip_configuration_name   = "primary"
  backend_address_pool_id = local.ingress_backend_pool_id
}

resource "azurerm_network_interface" "sriov_worker_multus" {
  name                  = "nic-worker-sriov-multus-${var.cluster_name}"
  location              = var.location
  resource_group_name   = local.workload_rg
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "multus"
    subnet_id                     = local.subnet_multus_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

# SR-IOV NIC: Accelerated Networking enabled => Azure exposes a VF (`enP*`)
# bonded with the synthetic NIC (`eth2`). The Multus host-device CNI
# moves the VF into a pod's netns for direct hardware passthrough.
resource "azurerm_network_interface" "sriov_worker_sriov" {
  name                           = "nic-worker-sriov-sriov-${var.cluster_name}"
  location                       = var.location
  resource_group_name            = local.workload_rg
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "sriov"
    subnet_id                     = local.subnet_sriov_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
  }
}

resource "azurerm_linux_virtual_machine" "sriov_worker" {
  name                = "vm-worker-sriov-${var.cluster_name}"
  location            = var.location
  resource_group_name = local.workload_rg
  size                = var.sriov_worker_vm_size
  zone                = var.sriov_worker_zone
  admin_username      = "core"
  network_interface_ids = [
    azurerm_network_interface.sriov_worker_primary.id,
    azurerm_network_interface.sriov_worker_multus.id,
    azurerm_network_interface.sriov_worker_sriov.id,
  ]
  source_image_id                 = local.image_id
  disable_password_authentication = true
  custom_data                     = base64encode(local.worker_ignition)
  tags                            = var.tags

  admin_ssh_key {
    username   = "core"
    public_key = local.ssh_pub
  }

  os_disk {
    name                 = "osdisk-worker-sriov-${var.cluster_name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  boot_diagnostics {}
}
