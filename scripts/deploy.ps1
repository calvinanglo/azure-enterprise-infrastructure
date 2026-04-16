#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the enterprise infrastructure stack to Azure.

.DESCRIPTION
    Orchestrates a full deployment: validates prerequisites, runs what-if,
    then deploys all Bicep modules at subscription scope.

.PARAMETER Environment
    Target environment: dev, staging, or prod.

.PARAMETER Location
    Primary Azure region (default: eastus2).

.PARAMETER SkipWhatIf
    Skip the what-if preview and deploy immediately.

.EXAMPLE
    .\deploy.ps1 -Environment prod -Location eastus2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$Location = 'eastus2',

    [switch]$SkipWhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$deploymentName = "enterprise-infra-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$templateFile = Join-Path $PSScriptRoot '..\bicep\main.bicep'
$paramFile = Join-Path $PSScriptRoot "..\bicep\parameters\$Environment.bicepparam"

# ── Pre-flight Checks ──────────────────────────────────────────────────────

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Enterprise Infrastructure Deployment"   -ForegroundColor Cyan
Write-Host "  Environment : $Environment"              -ForegroundColor Cyan
Write-Host "  Location    : $Location"                 -ForegroundColor Cyan
Write-Host "  Deployment  : $deploymentName"           -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Verify Azure CLI
Write-Host "[1/6] Checking Azure CLI..." -ForegroundColor Yellow
$azVersion = az version --output json | ConvertFrom-Json
Write-Host "  Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
Write-Host "  Bicep CLI: $($azVersion.'bicep-cli')" -ForegroundColor Green

# Verify logged in
Write-Host "[2/6] Verifying authentication..." -ForegroundColor Yellow
$account = az account show --output json | ConvertFrom-Json
Write-Host "  Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
Write-Host "  Tenant      : $($account.tenantId)" -ForegroundColor Green

# Verify template exists
Write-Host "[3/6] Validating template files..." -ForegroundColor Yellow
if (-not (Test-Path $templateFile)) {
    throw "Template not found: $templateFile"
}
if (-not (Test-Path $paramFile)) {
    throw "Parameter file not found: $paramFile"
}
Write-Host "  Template  : $templateFile" -ForegroundColor Green
Write-Host "  Parameters: $paramFile" -ForegroundColor Green

# Bicep build (syntax validation)
Write-Host "[4/6] Building Bicep (syntax check)..." -ForegroundColor Yellow
az bicep build --file $templateFile --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Bicep build failed" }
Write-Host "  Bicep compiled successfully" -ForegroundColor Green

# What-If
if (-not $SkipWhatIf) {
    Write-Host "[5/6] Running what-if preview..." -ForegroundColor Yellow
    az deployment sub what-if `
        --name $deploymentName `
        --location $Location `
        --template-file $templateFile `
        --parameters $paramFile `
        --result-format FullResourcePayloads

    Write-Host "`n" -NoNewline
    $continue = Read-Host "Review the changes above. Continue with deployment? (y/N)"
    if ($continue -ne 'y') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
} else {
    Write-Host "[5/6] Skipping what-if (--SkipWhatIf)" -ForegroundColor DarkYellow
}

# Deploy
Write-Host "[6/6] Deploying to Azure..." -ForegroundColor Yellow
$startTime = Get-Date

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters $paramFile `
    --verbose

if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed. Check Azure Portal > Deployments for details."
}

$duration = (Get-Date) - $startTime

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Deployment Succeeded!" -ForegroundColor Green
Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# Output key values
Write-Host "Key Outputs:" -ForegroundColor Cyan
az deployment sub show `
    --name $deploymentName `
    --query "properties.outputs" `
    --output table
