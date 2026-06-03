# 02-create-subnets-and-nsg.ps1 - create the 5 OpenShift subnets and the
# master + worker NSGs (with the minimum rules from docs/network-prereqs.md).
#
# Subnets are NOT given a route table here - that is done by
# 03-create-udr.ps1.

[CmdletBinding()]
param(
  [string]$Location          = ($env:LOCATION              ?? 'northeurope'),
  [string]$NetworkRg         = ($env:NETWORK_RG            ?? 'REDACTED_RESOURCE_GROUPwork'),
  [string]$VnetName          = ($env:VNET_NAME             ?? 'vnet-ocp-spoke'),
  [string]$MasterCidr        = ($env:SUBNET_MASTER_CIDR    ?? '10.20.0.0/27'),
  [string]$BootstrapCidr     = ($env:SUBNET_BOOTSTRAP_CIDR ?? '10.20.0.32/28'),
  [string]$WorkerCidr        = ($env:SUBNET_WORKER_CIDR    ?? '10.20.1.0/24'),
  [string]$MultusCidr        = ($env:SUBNET_MULTUS_CIDR    ?? '10.20.2.0/24'),
  [string]$SriovCidr         = ($env:SUBNET_SRIOV_CIDR     ?? '10.20.3.0/27'),
  [string]$NsgMaster         = ($env:NSG_MASTER            ?? 'nsg-ocp-master'),
  [string]$NsgWorker         = ($env:NSG_WORKER            ?? 'nsg-ocp-worker')
)

$ErrorActionPreference = 'Stop'

function New-Nsg([string]$Name) {
  Write-Host "==> NSG: $Name"
  az network nsg create `
    --resource-group $NetworkRg `
    --name $Name `
    --location $Location `
    --only-show-errors `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nsg create failed for $Name" }
}

function New-NsgRule([string]$Nsg, [string]$Name, [int]$Prio, [string]$Ports, [string]$Description) {
  az network nsg rule create `
    --resource-group $NetworkRg `
    --nsg-name $Nsg `
    --name $Name `
    --priority $Prio `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --source-address-prefixes VirtualNetwork `
    --source-port-ranges '*' `
    --destination-address-prefixes '*' `
    --destination-port-ranges $Ports.Split(' ') `
    --description $Description `
    --only-show-errors `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create failed for $Nsg/$Name" }
}

function New-LbHealthProbeRule([string]$Nsg) {
  az network nsg rule create `
    --resource-group $NetworkRg `
    --nsg-name $Nsg `
    --name allow-azure-lb `
    --priority 4000 `
    --direction Inbound `
    --access Allow `
    --protocol '*' `
    --source-address-prefixes AzureLoadBalancer `
    --source-port-ranges '*' `
    --destination-address-prefixes '*' `
    --destination-port-ranges '*' `
    --description 'Allow Azure LB health probes' `
    --only-show-errors `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create failed for $Nsg/allow-azure-lb" }
}

New-Nsg $NsgMaster
New-NsgRule $NsgMaster 'allow-api'     100 '6443'        'Cluster API'
New-NsgRule $NsgMaster 'allow-mcs'     110 '22623'       'Machine Config Server'
New-NsgRule $NsgMaster 'allow-ssh'     120 '22'          'SSH from VNet'
New-NsgRule $NsgMaster 'allow-control' 130 '9000-9999'   'etcd, controller-manager, scheduler'
New-NsgRule $NsgMaster 'allow-kubelet' 140 '10250-10259' 'kubelet, etcd-events'
New-LbHealthProbeRule $NsgMaster

New-Nsg $NsgWorker
New-NsgRule $NsgWorker 'allow-http'      100 '80'          'Apps HTTP ingress'
New-NsgRule $NsgWorker 'allow-https'     110 '443'         'Apps HTTPS ingress'
New-NsgRule $NsgWorker 'allow-ssh'       120 '22'          'SSH from VNet'
New-NsgRule $NsgWorker 'allow-kubelet'   130 '10250-10259' 'kubelet'
New-NsgRule $NsgWorker 'allow-nodeport'  140 '30000-32767' 'NodePort (if used)'
New-LbHealthProbeRule $NsgWorker

function New-Subnet([string]$Name, [string]$Cidr, [string]$Nsg) {
  Write-Host "==> Subnet: $Name ($Cidr)"
  $args = @(
    'network','vnet','subnet','create',
    '--resource-group', $NetworkRg,
    '--vnet-name',      $VnetName,
    '--name',           $Name,
    '--address-prefixes', $Cidr,
    '--only-show-errors',
    '--output', 'none'
  )
  if ($Nsg) {
    $args += @('--network-security-group', $Nsg)
  }
  & az @args
  if ($LASTEXITCODE -ne 0) { throw "az network vnet subnet create failed for $Name" }
}

New-Subnet 'snet-ocp-master'    $MasterCidr    $NsgMaster
New-Subnet 'snet-ocp-bootstrap' $BootstrapCidr $NsgWorker
New-Subnet 'snet-ocp-worker'    $WorkerCidr    $NsgWorker
New-Subnet 'snet-ocp-multus'    $MultusCidr    $NsgWorker
New-Subnet 'snet-ocp-sriov'     $SriovCidr     $NsgWorker

Write-Host ""
Write-Host "==> Subnet IDs (paste into terraform/01-network/terraform.tfvars):"
foreach ($sn in @('snet-ocp-master','snet-ocp-bootstrap','snet-ocp-worker','snet-ocp-multus','snet-ocp-sriov')) {
  $id  = az network vnet subnet show -g $NetworkRg --vnet-name $VnetName -n $sn --query id -o tsv
  $var = ($sn -replace '-','_') + '_id'
  Write-Host ("  {0,-22} = {1}" -f $var, $id)
}
