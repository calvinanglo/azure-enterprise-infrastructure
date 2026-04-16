#Requires -Version 7.0
<#
.SYNOPSIS
    Controlled teardown of enterprise infrastructure.

.DESCRIPTION
    Removes resource groups in reverse dependency order. Requires explicit confirmation.
    Removes resource locks first (prod), then deletes resource groups.

.PARAMETER Environment
    Target environment to tear down.

.PARAMETER Confirm
    Required flag to prevent accidental execution.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [switch]$Confirm
)

$ErrorActionPreference = 'Stop'

$orgPrefix = 'ent'
$resourceGroups = @(
    "$orgPrefix-rg-compute-$Environment"
    "$orgPrefix-rg-storage-$Environment"
    "$orgPrefix-rg-security-$Environment"
    "$orgPrefix-rg-monitoring-$Environment"
    "$orgPrefix-rg-networking-$Environment"    # Deleted last (peering dependencies)
)

if (-not $Confirm) {
    Write-Host "`nERROR: You must pass -Confirm to execute teardown." -ForegroundColor Red
    Write-Host "Usage: .\teardown.ps1 -Environment $Environment -Confirm`n" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  TEARDOWN: $Environment environment"     -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

# Double-confirm for production
if ($Environment -eq 'prod') {
    $prodConfirm = Read-Host "Type 'DELETE PRODUCTION' to confirm production teardown"
    if ($prodConfirm -ne 'DELETE PRODUCTION') {
        Write-Host "Teardown cancelled." -ForegroundColor Yellow
        exit 0
    }

    # Remove resource locks first
    Write-Host "Removing resource locks..." -ForegroundColor Yellow
    foreach ($rg in $resourceGroups) {
        $locks = az lock list --resource-group $rg --output json 2>$null | ConvertFrom-Json
        foreach ($lock in $locks) {
            Write-Host "  Removing lock: $($lock.name) on $rg" -ForegroundColor DarkYellow
            az lock delete --name $lock.name --resource-group $rg
        }
    }
}

# Delete resource groups
foreach ($rg in $resourceGroups) {
    $exists = az group exists --name $rg --output tsv
    if ($exists -eq 'true') {
        Write-Host "Deleting: $rg ..." -ForegroundColor Yellow
        az group delete --name $rg --yes --no-wait
        Write-Host "  Deletion initiated (async)" -ForegroundColor DarkYellow
    } else {
        Write-Host "Skipping: $rg (does not exist)" -ForegroundColor Gray
    }
}

Write-Host "`nTeardown initiated. Resource groups are being deleted asynchronously." -ForegroundColor Green
Write-Host "Monitor progress: az group list --query `"[?starts_with(name,'$orgPrefix-rg')].{Name:name,State:properties.provisioningState}`" --output table`n" -ForegroundColor Cyan
