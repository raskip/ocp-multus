output "bootstrap_vm_name" { value = azurerm_linux_virtual_machine.bootstrap.name }
output "bootstrap_nic_ip" {
  value = azurerm_network_interface.bootstrap.ip_configuration[0].private_ip_address
}
