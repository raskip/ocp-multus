data "azurerm_virtual_network" "shared" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group
}

data "azurerm_resource_group" "workload" {
  name = var.workload_resource_group_name
}

data "terraform_remote_state" "prereqs" {
  backend = "local"
  config = {
    path = "../00-prereqs/terraform.tfstate"
  }
}

locals {
  storage_account_id   = data.terraform_remote_state.prereqs.outputs.storage_account_id
  storage_account_name = data.terraform_remote_state.prereqs.outputs.storage_account_name

  uploader_vm_size_default   = var.architecture == "x86_64" ? "Standard_D2s_v5" : "Standard_D2ps_v5"
  uploader_image_sku_default = var.architecture == "x86_64" ? "server" : "server-arm64"
  uploader_vm_size           = var.uploader_vm_size != "" ? var.uploader_vm_size : local.uploader_vm_size_default
  uploader_image_sku         = var.uploader_image_sku != "" ? var.uploader_image_sku : local.uploader_image_sku_default
}

#-----------------------------------------------------------------------------
# NSGs (repo-managed mode only — when manage_network_resources = true).
# In BYO-network mode (manage_network_resources = false), the customer's
# network team has already created and attached NSGs to the subnets;
# we don't reference them from here.
#-----------------------------------------------------------------------------
resource "azurerm_network_security_group" "master" {
  count               = var.manage_network_resources ? 1 : 0
  name                = "nsg-ocp-master-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  security_rule {
    name                       = "ssh-uploader-from-admin"
    priority                   = 500
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_ssh_source_ip
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "api-6443"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "mcs-22623"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22623"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "intra-cluster"
    priority                   = 1100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "worker" {
  count               = var.manage_network_resources ? 1 : 0
  name                = "${var.infra_id}-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  lifecycle {
    create_before_destroy = true
  }

  security_rule {
    name                       = "http-80"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "https-443"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "intra-cluster"
    priority                   = 1100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

#-----------------------------------------------------------------------------
# Subnets carved out of the existing VNet (repo-managed mode only — when
# manage_network_resources = true). In BYO mode the customer's network
# team has already created the subnets; we just consume the IDs.
#
# Created via azapi so the NSG is inline at creation time — required by
# policy "Subnets must have a Network Security Group" in many tenants.
#-----------------------------------------------------------------------------
locals {
  vnet_id = data.azurerm_virtual_network.shared.id
}

resource "azapi_resource" "subnet_master" {
  count                     = var.manage_network_resources ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-master"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix                     = var.subnet_master_cidr
        networkSecurityGroup              = { id = azurerm_network_security_group.master[0].id }
        privateEndpointNetworkPolicies    = "Disabled"
        privateLinkServiceNetworkPolicies = "Enabled"
      },
      contains(var.attach_route_table_to_extra_subnets, "master") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
}

resource "azurerm_route_table" "node" {
  count               = var.manage_network_resources ? 1 : 0
  name                = "${var.infra_id}-node-routetable"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  lifecycle {
    # Azure cloud-provider mutates routes on this table; ignore drift.
    ignore_changes = [route]
  }
}

resource "azapi_resource" "subnet_worker" {
  count                     = var.manage_network_resources ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-worker"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = {
      addressPrefix        = var.subnet_worker_cidr
      networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      routeTable           = { id = azurerm_route_table.node[0].id }
    }
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_master]
}

resource "azapi_resource" "subnet_bootstrap" {
  count                     = var.manage_network_resources ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-bootstrap"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_bootstrap_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.master[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "bootstrap") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_worker]
}

resource "azapi_resource" "subnet_multus" {
  count                     = var.manage_network_resources ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-multus"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_multus_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "multus") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_bootstrap]
}

# CIDR-overlap guard for the SR-IOV subnet. The Multus subnet defaults to
# 10.20.2.0/23, which spans the range SR-IOV historically used, so when SR-IOV
# is enabled we assert its CIDR does not overlap Multus. _ovl_start maps each
# CIDR to its integer network address; _ovl_size to its address count.
locals {
  _ovl_cidrs = [var.subnet_multus_cidr, var.subnet_sriov_cidr]
  _ovl_start = { for c in local._ovl_cidrs : c => sum([for i, o in split(".", split("/", c)[0]) : tonumber(o) * pow(256, 3 - i)]) }
  _ovl_size  = { for c in local._ovl_cidrs : c => pow(2, 32 - tonumber(split("/", c)[1])) }
}

resource "azapi_resource" "subnet_sriov" {
  count                     = var.manage_network_resources && var.enable_sriov ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-sriov"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_sriov_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "sriov") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_multus]

  lifecycle {
    precondition {
      condition     = (local._ovl_start[var.subnet_multus_cidr] > local._ovl_start[var.subnet_sriov_cidr] + local._ovl_size[var.subnet_sriov_cidr] - 1) || (local._ovl_start[var.subnet_sriov_cidr] > local._ovl_start[var.subnet_multus_cidr] + local._ovl_size[var.subnet_multus_cidr] - 1)
      error_message = "subnet_sriov_cidr (${var.subnet_sriov_cidr}) overlaps subnet_multus_cidr (${var.subnet_multus_cidr}). Choose non-overlapping ranges, e.g. relocate SR-IOV to 10.20.7.0/24."
    }
  }
}

#-----------------------------------------------------------------------------
# Optional CNF / telco LAN subnets (created only when enable_cnf_lans =
# true AND manage_network_resources = true). Same azapi pattern as the subnets
# above: worker NSG inline + optional route-table attach. Default OFF.
#-----------------------------------------------------------------------------
resource "azapi_resource" "subnet_oam" {
  count                     = var.manage_network_resources && var.enable_cnf_lans ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-oam"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_oam_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "oam") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_sriov]
}

resource "azapi_resource" "subnet_ausfudm" {
  count                     = var.manage_network_resources && var.enable_cnf_lans ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-ausfudm"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_ausfudm_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "ausfudm") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_oam]
}

resource "azapi_resource" "subnet_hsshlr" {
  count                     = var.manage_network_resources && var.enable_cnf_lans ? 1 : 0
  type                      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name                      = "snet-ocp-hsshlr"
  parent_id                 = local.vnet_id
  schema_validation_enabled = false
  body = {
    properties = merge(
      {
        addressPrefix        = var.subnet_hsshlr_cidr
        networkSecurityGroup = { id = azurerm_network_security_group.worker[0].id }
      },
      contains(var.attach_route_table_to_extra_subnets, "hsshlr") ? {
        routeTable = { id = azurerm_route_table.node[0].id }
      } : {}
    )
  }
  response_export_values = ["id"]
  depends_on             = [azapi_resource.subnet_ausfudm]
}

#-----------------------------------------------------------------------------
# Subnet IDs (and the route-table ID) used by every downstream resource in
# this stack. In repo-managed mode they come from the azapi/azurerm
# resources above; in BYO mode they come from the var.subnet_*_id inputs.
#-----------------------------------------------------------------------------
locals {
  subnet_master_id    = var.manage_network_resources ? azapi_resource.subnet_master[0].id : var.subnet_master_id
  subnet_worker_id    = var.manage_network_resources ? azapi_resource.subnet_worker[0].id : var.subnet_worker_id
  subnet_bootstrap_id = var.manage_network_resources ? azapi_resource.subnet_bootstrap[0].id : var.subnet_bootstrap_id
  subnet_multus_id    = var.manage_network_resources ? azapi_resource.subnet_multus[0].id : var.subnet_multus_id
  subnet_sriov_id     = var.manage_network_resources ? one(azapi_resource.subnet_sriov[*].id) : var.subnet_sriov_id
  subnet_oam_id       = var.manage_network_resources ? one(azapi_resource.subnet_oam[*].id) : var.subnet_oam_id
  subnet_ausfudm_id   = var.manage_network_resources ? one(azapi_resource.subnet_ausfudm[*].id) : var.subnet_ausfudm_id
  subnet_hsshlr_id    = var.manage_network_resources ? one(azapi_resource.subnet_hsshlr[*].id) : var.subnet_hsshlr_id
  route_table_id      = var.manage_network_resources ? azurerm_route_table.node[0].id : var.route_table_id
}

#-----------------------------------------------------------------------------
# Internal load balancers
#-----------------------------------------------------------------------------
resource "azurerm_lb" "api_internal" {
  name                = "lb-api-internal-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "api-int-frontend"
    subnet_id                     = local.subnet_master_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "api_internal" {
  name            = "api-internal-backend"
  loadbalancer_id = azurerm_lb.api_internal.id
}

resource "azurerm_lb_probe" "api_6443" {
  name                = "https-readyz-6443"
  loadbalancer_id     = azurerm_lb.api_internal.id
  protocol            = "Https"
  port                = 6443
  request_path        = "/readyz"
  interval_in_seconds = 10
  number_of_probes    = 3

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_lb_probe" "mcs_22623" {
  name                = "https-healthz-22623"
  loadbalancer_id     = azurerm_lb.api_internal.id
  protocol            = "Https"
  port                = 22623
  request_path        = "/healthz"
  interval_in_seconds = 10
  number_of_probes    = 3

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_lb_rule" "api_6443" {
  name                           = "api-6443"
  loadbalancer_id                = azurerm_lb.api_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "api-int-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api_internal.id]
  probe_id                       = azurerm_lb_probe.api_6443.id
}

resource "azurerm_lb_rule" "mcs_22623" {
  name                           = "mcs-22623"
  loadbalancer_id                = azurerm_lb.api_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 22623
  backend_port                   = 22623
  frontend_ip_configuration_name = "api-int-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api_internal.id]
  probe_id                       = azurerm_lb_probe.mcs_22623.id
}

resource "azurerm_lb" "ingress_internal" {
  name                = "lb-ingress-internal-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "ingress-frontend"
    subnet_id                     = local.subnet_worker_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "ingress_internal" {
  name            = "ingress-internal-backend"
  loadbalancer_id = azurerm_lb.ingress_internal.id
}

resource "azurerm_lb_probe" "ingress_80" {
  name                = "tcp-80"
  loadbalancer_id     = azurerm_lb.ingress_internal.id
  protocol            = "Tcp"
  port                = 80
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_probe" "ingress_443" {
  name                = "tcp-443"
  loadbalancer_id     = azurerm_lb.ingress_internal.id
  protocol            = "Tcp"
  port                = 443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "ingress_80" {
  name                           = "http-80"
  loadbalancer_id                = azurerm_lb.ingress_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "ingress-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.ingress_internal.id]
  probe_id                       = azurerm_lb_probe.ingress_80.id
}

resource "azurerm_lb_rule" "ingress_443" {
  name                           = "https-443"
  loadbalancer_id                = azurerm_lb.ingress_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "ingress-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.ingress_internal.id]
  probe_id                       = azurerm_lb_probe.ingress_443.id
}

#-----------------------------------------------------------------------------
# Private DNS records for cluster endpoints (zone created in 00-prereqs)
#
# B62 fix: the cluster zone is named "${cluster_name}.${private_dns_zone_name}"
# by default so the ingress-operator's dns-controller can find it and write
# *.apps records itself. Records use short names ("api", "api-int", "*.apps")
# because the cluster_name is now part of the zone name.
#
# Legacy layout (use_legacy_dns_layout=true): zone is named just
# "${private_dns_zone_name}" and records use long names like "api.${cluster_name}".
# Both layouts produce the SAME FQDN. Only the default (new) layout works
# with the ingress-operator's dynamic record management — see the variable
# docstring for full background.
#-----------------------------------------------------------------------------
locals {
  cluster_dns_zone_name = var.use_legacy_dns_layout ? var.private_dns_zone_name : "${var.cluster_name}.${var.private_dns_zone_name}"

  api_record_name     = var.use_legacy_dns_layout ? "api.${var.cluster_name}" : "api"
  api_int_record_name = var.use_legacy_dns_layout ? "api-int.${var.cluster_name}" : "api-int"
  apps_record_name    = var.use_legacy_dns_layout ? "*.apps.${var.cluster_name}" : "*.apps"
}

resource "azurerm_private_dns_a_record" "api" {
  name                = local.api_record_name
  zone_name           = local.cluster_dns_zone_name
  resource_group_name = data.azurerm_resource_group.workload.name
  ttl                 = 300
  records             = [azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address]
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "api_int" {
  name                = local.api_int_record_name
  zone_name           = local.cluster_dns_zone_name
  resource_group_name = data.azurerm_resource_group.workload.name
  ttl                 = 300
  records             = [azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address]
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "apps" {
  name                = local.apps_record_name
  zone_name           = local.cluster_dns_zone_name
  resource_group_name = data.azurerm_resource_group.workload.name
  ttl                 = 300
  records             = [azurerm_lb.ingress_internal.frontend_ip_configuration[0].private_ip_address]
  tags                = var.tags
}

#-----------------------------------------------------------------------------
# Storage account private endpoint (account lives in workload RG from 00-prereqs)
# DNS is registered in the centralized hub zone; no local private DNS zone.
#-----------------------------------------------------------------------------
resource "azurerm_private_endpoint" "storage_blob" {
  name                = "pe-${local.storage_account_name}-blob"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  subnet_id           = local.subnet_master_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = local.storage_account_id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
}

resource "azurerm_private_dns_a_record" "blob_pe" {
  provider            = azurerm.private_dns
  name                = local.storage_account_name
  zone_name           = "privatelink.blob.core.windows.net"
  resource_group_name = var.hub_dns_resource_group
  ttl                 = 30
  records             = [azurerm_private_endpoint.storage_blob.private_service_connection[0].private_ip_address]
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_hub" {
  provider              = azurerm.private_dns
  name                  = "vnetlink-${var.vnet_name}-blob"
  resource_group_name   = var.hub_dns_resource_group
  private_dns_zone_name = "privatelink.blob.core.windows.net"
  virtual_network_id    = data.azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = var.tags
}

#-----------------------------------------------------------------------------
# Uploader jumpbox: WSL cannot reach the storage Private Endpoint, so we run
# blob operations (RHCOS copy, ignition upload, user-delegation SAS) inside
# the VNet via `az vm run-command invoke`.
#-----------------------------------------------------------------------------
resource "azurerm_network_interface" "uploader" {
  name                = "nic-uploader-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_bootstrap_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "uploader" {
  name                            = "vm-uploader-${var.cluster_name}"
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.workload.name
  size                            = local.uploader_vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.uploader.id]
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = local.uploader_image_sku
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(<<-EOT
    #cloud-config
    package_update: true
    packages:
      - curl
      - ca-certificates
      - apt-transport-https
      - gnupg
      - lsb-release
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      - touch /var/lib/uploader-ready
  EOT
  )
}

resource "azurerm_role_assignment" "uploader_blob_contributor" {
  scope                = local.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.uploader.identity[0].principal_id
}

#-----------------------------------------------------------------------------
# Optional Linux bastion: persistent in-VNet tooling host (Helm / Python / oc /
# az) for operating CNF workloads and reaching internal load balancers (e.g. the
# ZTS Envoy LB on TCP 8175/8099). No public IP — SSH in from admin_ssh_source_ip
# (allowed by the master NSG on the bootstrap subnet) or via a jump host.
# Default OFF (create_linux_bastion = false).
#-----------------------------------------------------------------------------
resource "azurerm_network_interface" "cnf_bastion" {
  count               = var.create_linux_bastion ? 1 : 0
  name                = "nic-cnf-bastion-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_bootstrap_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "cnf_bastion" {
  count                           = var.create_linux_bastion ? 1 : 0
  name                            = "vm-cnf-bastion-${var.cluster_name}"
  location                        = var.location
  resource_group_name             = data.azurerm_resource_group.workload.name
  size                            = local.uploader_vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.cnf_bastion[0].id]
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = local.uploader_image_sku
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(<<-EOT
    #cloud-config
    package_update: true
    packages:
      - curl
      - ca-certificates
      - python3
      - python3-pip
      - tar
      - gzip
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      - curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      - curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz -o /tmp/oc.tar.gz
      - tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl
      - touch /var/lib/bastion-ready
  EOT
  )
}

#-----------------------------------------------------------------------------
# Windows jump VM: optional in-VNet browser host for accessing an internal
# OpenShift console when the cluster is deployed with publish = Internal.
#-----------------------------------------------------------------------------
resource "random_password" "win_jump" {
  count            = var.create_windows_jump ? 1 : 0
  length           = 20
  special          = true
  override_special = "!@#$%*()-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "win_jump" {
  count               = var.create_windows_jump ? 1 : 0
  name                = "nic-jump-win-${var.cluster_name}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_bootstrap_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "win_jump" {
  count                 = var.create_windows_jump ? 1 : 0
  name                  = "vm-jump-win-${var.cluster_name}"
  computer_name         = "winjump"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.workload.name
  size                  = "Standard_D2s_v5"
  admin_username        = "azureuser"
  admin_password        = random_password.win_jump[0].result
  network_interface_ids = [azurerm_network_interface.win_jump[0].id]
  tags                  = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}
