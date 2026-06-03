# 01-create-vnet.ps1 - create the network resource group and the spoke VNet.
#
# Re-running is safe: az ... create is idempotent in the typical case.

[CmdletBinding()]
param(
  [string]$Location  = ($env:LOCATION    ?? 'northeurope'),
  [string]$NetworkRg = ($env:NETWORK_RG  ?? 'REDACTED_RESOURCE_GROUPwork'),
  [string]$VnetName  = ($env:VNET_NAME   ?? 'vnet-ocp-spoke'),
  [string]$VnetCidr  = ($env:VNET_CIDR   ?? '10.20.0.0/22')
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Resource group: $NetworkRg ($Location)"
az group create `
  --name $NetworkRg `
  --location $Location `
  --only-show-errors `
  --output none
if ($LASTEXITCODE -ne 0) { throw "az group create failed" }

Write-Host "==> VNet: $VnetName ($VnetCidr)"
az network vnet create `
  --resource-group $NetworkRg `
  --name $VnetName `
  --address-prefixes $VnetCidr `
  --location $Location `
  --only-show-errors `
  --output none
if ($LASTEXITCODE -ne 0) { throw "az network vnet create failed" }

Write-Host "==> Done."
Write-Host ""
az network vnet show `
  --resource-group $NetworkRg `
  --name $VnetName `
  --query '{name:name, cidr:addressSpace.addressPrefixes, location:location, id:id}' `
  -o jsonc
