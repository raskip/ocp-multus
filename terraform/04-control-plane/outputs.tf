output "master_vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.master : vm.name]
}
output "master_private_ips" {
  value = [for n in azurerm_network_interface.master : n.ip_configuration[0].private_ip_address]
}
