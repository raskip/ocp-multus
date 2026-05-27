# 00-preflight.ps1 - verify az CLI is logged in, on the right subscription,
# and has the extensions required by the later scripts in this directory.
#
# This script does not modify any Azure resources.

[CmdletBinding()]
param(
  [string]$SubscriptionId = $env:SUBSCRIPTION_ID
)

$ErrorActionPreference = 'Stop'

Write-Host "==> az CLI version"
az version --query '"azure-cli"' -o tsv

Write-Host "==> Signed-in account"
$accountJson = az account show -o json 2>$null
if (-not $accountJson) {
  Write-Error "Not logged in. Run 'az login' or 'az login --use-device-code'."
  exit 1
}
$a = $accountJson | ConvertFrom-Json
Write-Host ("  user:         " + $a.user.name)
Write-Host ("  tenantId:     " + $a.tenantId)
Write-Host ("  subscription: " + $a.name + " (" + $a.id + ")")

if ($SubscriptionId) {
  $current = az account show --query id -o tsv
  if ($current -ne $SubscriptionId) {
    Write-Host "==> Setting subscription to $SubscriptionId"
    az account set --subscription $SubscriptionId
  }
}

Write-Host "==> Required CLI extensions"
# Pre-install so later scripts never prompt interactively.
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors | Out-Null

foreach ($ext in @('azure-firewall')) {
  $shown = az extension show --name $ext 2>$null
  if ($shown) {
    Write-Host "  ok: $ext"
  } else {
    Write-Host "  installing: $ext"
    az extension add --name $ext --only-show-errors | Out-Null
  }
}

Write-Host "==> Preflight passed."
