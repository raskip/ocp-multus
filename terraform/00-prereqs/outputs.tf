output "workload_resource_group_name" {
  value = azurerm_resource_group.workload.name
}

output "workload_location" {
  value = azurerm_resource_group.workload.location
}

output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.cluster.name
}

output "private_dns_zone_id" {
  value = azurerm_private_dns_zone.cluster.id
}

# null when create_public_dns = false (internal-only).
output "public_dns_subzone_name" {
  value = one(azurerm_dns_zone.public_subzone[*].name)
}

output "public_dns_subzone_nameservers" {
  value = one(azurerm_dns_zone.public_subzone[*].name_servers)
}

output "storage_account_name" {
  value = azurerm_storage_account.ocp.name
}

output "storage_account_id" {
  value = azurerm_storage_account.ocp.id
}

output "ignition_container_name" {
  value = azurerm_storage_container.ignition.name
}

output "rhcos_container_name" {
  value = azurerm_storage_container.rhcos.name
}

output "vnet_id" {
  value = data.azurerm_virtual_network.shared.id
}
