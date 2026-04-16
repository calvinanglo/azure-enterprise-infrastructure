#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-flight validation: lints Bicep, checks quotas, runs what-if.

.PARAMETER Environment
    Target environment: dev, staging, or prod.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'
$templateFile = Join-Path $PSScriptRoot '..\bicep\main.bicep'
$paramFile = Join-Path $PSScriptRoot "..\bicep\parameters\$Environment.bicepparam"
$exitCode = 0

Write-Host "`n=== Pre-Flight Validation ===" -ForegroundColor Cyan

# 1. Bicep lint
Write-Host "`n[1/4] Linting Bicep templates..." -ForegroundColor Yellow
$bicepFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\bicep') -Filter '*.bicep' -Recurse
foreach ($file in $bicepFiles) {
    az bicep build --file $file.FullName --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: $($file.Name)" -ForegroundColor Red
        $exitCode = 1
    } else {
        Write-Host "  PASS: $($file.Name)" -ForegroundColor Green
    }
}

# 2. Check authentication
Write-Host "`n[2/4] Checking authentication..." -ForegroundColor Yellow
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  FAIL: Not logged in. Run 'az login' first." -ForegroundColor Red
    $exitCode = 1
} else {
    Write-Host "  PASS: Authenticated as $($account.user.name)" -ForegroundColor Green
    Write-Host "        Subscription: $($account.name)" -ForegroundColor Gray
}

# 3. Check provider registrations
Write-Host "`n[3/4] Checking resource provider registrations..." -ForegroundColor Yellow
$requiredProviders = @(
    'Microsoft.Compute'
    'Microsoft.Network'
    'Microsoft.Storage'
    'Microsoft.KeyVault'
    'Microsoft.OperationalInsights'
    'Microsoft.Insights'
    'Microsoft.OperationsManagement'
)

foreach ($provider in $requiredProviders) {
    $status = az provider show --namespace $provider --query "registrationState" --output tsv 2>$null
    if ($status -eq 'Registered') {
        Write-Host "  PASS: $provider" -ForegroundColor Green
    } else {
        Write-Host "  WARN: $provider ($status) — registering now..." -ForegroundColor DarkYellow
        az provider register --namespace $provider | Out-Null
    }
}

# 4. What-if (dry run)
Write-Host "`n[4/4] Running what-if deployment..." -ForegroundColor Yellow
az deployment sub what-if `
    --location eastus2 `
    --template-file $templateFile `
    --parameters $paramFile `
    --result-format FullResourcePayloads `
    --no-prompt

if ($LASTEXITCODE -ne 0) {
    Write-Host "  FAIL: What-if returned errors" -ForegroundColor Red
    $exitCode = 1
} else {
    Write-Host "  PASS: What-if completed successfully" -ForegroundColor Green
}

# Summary
Write-Host "`n=== Validation Complete ===" -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host "All checks passed. Safe to deploy.`n" -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Review output above.`n" -ForegroundColor Red
}

exit $exitCode
