# 99-cleanup.ps1 - tear down everything 01/02/03 created by deleting the
# network resource group.
#
# WARNING: this deletes the entire NetworkRg, including ANYTHING ELSE
# in it. Verify the RG name and contents before confirming.

[CmdletBinding()]
param(
  [string]$NetworkRg = ($env:NETWORK_RG ?? 'REDACTED_RESOURCE_GROUPwork'),
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$exists = az group show -n $NetworkRg 2>$null
if (-not $exists) {
  Write-Host "==> Resource group '$NetworkRg' not found - nothing to do."
  exit 0
}

Write-Host "==> Resources in $NetworkRg :"
az resource list -g $NetworkRg --query '[].{name:name, type:type}' -o table

if (-not $Yes) {
  $ans = Read-Host "Delete resource group '$NetworkRg' AND EVERYTHING IN IT? (yes/no)"
  if ($ans -ne 'yes') {
    Write-Host "Aborted."
    exit 0
  }
}

Write-Host "==> Deleting $NetworkRg ..."
az group delete --name $NetworkRg --yes --no-wait
Write-Host "==> Deletion queued (running in background)."
