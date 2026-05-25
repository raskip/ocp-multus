output "subnet_master_id" { value = local.subnet_master_id }
output "subnet_worker_id" { value = local.subnet_worker_id }
output "subnet_bootstrap_id" { value = local.subnet_bootstrap_id }
output "subnet_multus_id" { value = local.subnet_multus_id }
output "subnet_sriov_id" { value = local.subnet_sriov_id }

output "api_internal_backend_pool_id" { value = azurerm_lb_backend_address_pool.api_internal.id }
output "ingress_internal_backend_pool_id" { value = azurerm_lb_backend_address_pool.ingress_internal.id }
output "api_internal_frontend_ip" { value = azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address }
output "ingress_internal_frontend_ip" { value = azurerm_lb.ingress_internal.frontend_ip_configuration[0].private_ip_address }

output "uploader_vm_name" { value = azurerm_linux_virtual_machine.uploader.name }
output "uploader_resource_group" { value = data.azurerm_resource_group.workload.name }
output "storage_account_name" { value = local.storage_account_name }
output "storage_account_id" { value = local.storage_account_id }

output "win_jump_vm_name" { value = azurerm_windows_virtual_machine.win_jump.name }
output "win_jump_private_ip" { value = azurerm_network_interface.win_jump.private_ip_address }
output "win_jump_admin_username" { value = azurerm_windows_virtual_machine.win_jump.admin_username }
output "win_jump_admin_password" {
  value     = random_password.win_jump.result
  sensitive = true
}
