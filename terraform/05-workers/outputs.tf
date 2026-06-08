output "worker_vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.worker : vm.name]
}
output "worker_primary_ips" {
  value = [for n in azurerm_network_interface.worker_primary : n.ip_configuration[0].private_ip_address]
}
output "worker_multus_ips" {
  value = [for n in azurerm_network_interface.worker_multus : n.ip_configuration[0].private_ip_address]
}
output "worker_oam_ips" {
  value = [for n in azurerm_network_interface.worker_oam : n.ip_configuration[0].private_ip_address]
}
output "worker_ausfudm_ips" {
  value = [for n in azurerm_network_interface.worker_ausfudm : n.ip_configuration[0].private_ip_address]
}
output "worker_hsshlr_ips" {
  value = [for n in azurerm_network_interface.worker_hsshlr : n.ip_configuration[0].private_ip_address]
}
