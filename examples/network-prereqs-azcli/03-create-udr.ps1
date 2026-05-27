# 03-create-udr.ps1 - create the egress route table, default route to the
# hub firewall, and attach it to master/worker/bootstrap/multus subnets.

[CmdletBinding()]
param(
  [string]$Location         = ($env:LOCATION          ?? 'northeurope'),
  [string]$NetworkRg        = ($env:NETWORK_RG        ?? 'REDACTED_RESOURCE_GROUPwork'),
  [string]$VnetName         = ($env:VNET_NAME         ?? 'vnet-ocp-spoke'),
  [string]$RouteTableName   = ($env:ROUTE_TABLE_NAME  ?? 'rt-ocp-egress'),
  [Parameter(Mandatory = $false)]
  [string]$HubFwPrivateIp   = $env:HUB_FW_PRIVATE_IP,
  [string[]]$Subnets        = @('snet-ocp-master','snet-ocp-bootstrap','snet-ocp-worker','snet-ocp-multus')
)

$ErrorActionPreference = 'Stop'

if (-not $HubFwPrivateIp) {
  throw "Set -HubFwPrivateIp or `$env:HUB_FW_PRIVATE_IP to the private IP of your hub firewall NVA"
}

Write-Host "==> Route table: $RouteTableName"
az network route-table create `
  --resource-group $NetworkRg `
  --name $RouteTableName `
  --location $Location `
  --disable-bgp-route-propagation false `
  --only-show-errors `
  --output none
if ($LASTEXITCODE -ne 0) { throw "az network route-table create failed" }

Write-Host "==> Default route: 0.0.0.0/0 -> VirtualAppliance $HubFwPrivateIp"
az network route-table route create `
  --resource-group $NetworkRg `
  --route-table-name $RouteTableName `
  --name default-egress-fw `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address $HubFwPrivateIp `
  --only-show-errors `
  --output none
if ($LASTEXITCODE -ne 0) { throw "az network route-table route create failed" }

foreach ($sn in $Subnets) {
  Write-Host "==> Attach route table to subnet: $sn"
  az network vnet subnet update `
    --resource-group $NetworkRg `
    --vnet-name $VnetName `
    --name $sn `
    --route-table $RouteTableName `
    --only-show-errors `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network vnet subnet update failed for $sn" }
}

Write-Host ""
$rtId = az network route-table show -g $NetworkRg -n $RouteTableName --query id -o tsv
Write-Host "==> Route table ID (paste into terraform/01-network/terraform.tfvars):"
Write-Host "  route_table_id = $rtId"
