output "worker_vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.worker : vm.name]
}
output "worker_primary_ips" {
  value = [for n in azurerm_network_interface.worker_primary : n.ip_configuration[0].private_ip_address]
}
output "worker_multus_ips" {
  value = [for n in azurerm_network_interface.worker_multus : n.ip_configuration[0].private_ip_address]
}
