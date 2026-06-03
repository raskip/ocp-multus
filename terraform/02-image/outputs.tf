output "image_id" {
  description = "ID of the shared-image-version to use as source_image_id on VMs"
  value       = azurerm_shared_image_version.rhcos.id
}
