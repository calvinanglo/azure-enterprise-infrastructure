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
    # Mandatory parameter enforces explicit environment selection.
    # ValidateSet restricts input to known values — prevents typos that would
    # deploy into an unintended environment. AZ-104: always scope deployments
    # to a specific environment to avoid resource bleed between dev and prod.
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    # Default region is eastus2 — one of Microsoft's primary US regions with
    # broad service availability. Override this for multi-region or DR
    # deployments. AZ-104: Azure regions are paired (e.g., eastus2 ↔ centralus)
    # for geo-redundant services like GRS storage and Azure Site Recovery.
    [string]$Location = 'eastus2',

    # Switch parameter (boolean flag) — present means $true, absent means $false.
    # Use -SkipWhatIf in CI/CD pipelines where a human reviewer is not available
    # to review the what-if output, and the pipeline has already gated the run.
    [switch]$SkipWhatIf
)

# Stop immediately on any error rather than continuing with a broken state.
# Without this, PowerShell continues executing after non-terminating errors,
# which could cause partial deployments or misleading success messages.
$ErrorActionPreference = 'Stop'

# Set-StrictMode prevents use of uninitialized variables and other unsafe
# patterns. Version Latest enforces the strictest available ruleset.
Set-StrictMode -Version Latest

# Deployment name must be unique within the subscription scope. The timestamp
# suffix (yyyyMMdd-HHmmss) ensures re-running the script creates a new
# deployment record rather than overwriting the previous one. ARM deployment
# history is retained for up to 800 deployments per scope — this naming
# pattern makes audit history human-readable.
$deploymentName = "enterprise-infra-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Resolve file paths relative to the script's own directory ($PSScriptRoot)
# rather than the caller's current working directory. This makes the script
# portable — it works correctly regardless of where it is invoked from.
$templateFile = Join-Path $PSScriptRoot '..\bicep\main.bicep'

# Environment-specific parameter files allow the same Bicep template to be
# deployed with different SKUs, counts, and settings per environment.
# AZ-104: .bicepparam files are the Bicep-native alternative to ARM parameter
# JSON files, introduced in Bicep 0.18+.
$paramFile = Join-Path $PSScriptRoot "..\bicep\parameters\$Environment.bicepparam"

# ── Pre-flight Checks ──────────────────────────────────────────────────────
# These checks fail fast before any Azure API calls are made. The goal is to
# catch common misconfiguration (wrong subscription, missing files, CLI not
# installed) before spending time on a doomed deployment.

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Enterprise Infrastructure Deployment"   -ForegroundColor Cyan
Write-Host "  Environment : $Environment"              -ForegroundColor Cyan
Write-Host "  Location    : $Location"                 -ForegroundColor Cyan
Write-Host "  Deployment  : $deploymentName"           -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Verify Azure CLI is installed and log its version.
# The Bicep CLI version is also checked — Bicep is bundled with Azure CLI
# but must be up-to-date to support the latest Bicep language features.
# AZ-104: The Azure CLI (az) is the primary command-line tool for managing
# Azure resources; it wraps ARM REST API calls with a human-friendly syntax.
Write-Host "[1/6] Checking Azure CLI..." -ForegroundColor Yellow
$azVersion = az version --output json | ConvertFrom-Json
Write-Host "  Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
Write-Host "  Bicep CLI: $($azVersion.'bicep-cli')" -ForegroundColor Green

# Step 2: Confirm the operator is authenticated and the correct subscription
# is active. AZ-104: A single Azure account can have access to multiple
# subscriptions. Always confirm the active subscription before deploying to
# avoid resource creation in the wrong billing scope.
# 'az account show' returns the currently selected subscription context.
Write-Host "[2/6] Verifying authentication..." -ForegroundColor Yellow
$account = az account show --output json | ConvertFrom-Json
Write-Host "  Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
Write-Host "  Tenant      : $($account.tenantId)" -ForegroundColor Green

# Step 3: Confirm both the main Bicep template and the environment-specific
# parameter file exist on disk before calling any Azure APIs. A missing
# parameter file is a common error when adding a new environment.
Write-Host "[3/6] Validating template files..." -ForegroundColor Yellow
if (-not (Test-Path $templateFile)) {
    throw "Template not found: $templateFile"
}
if (-not (Test-Path $paramFile)) {
    throw "Parameter file not found: $paramFile"
}
Write-Host "  Template  : $templateFile" -ForegroundColor Green
Write-Host "  Parameters: $paramFile" -ForegroundColor Green

# Step 4: Compile the Bicep template to ARM JSON to catch syntax errors and
# missing module references before sending anything to Azure. '--stdout' sends
# the compiled ARM JSON to stdout (piped to Out-Null) — we only care about
# the exit code. AZ-104: 'az bicep build' performs local compilation only;
# it does not contact Azure, so this step works offline.
Write-Host "[4/6] Building Bicep (syntax check)..." -ForegroundColor Yellow
az bicep build --file $templateFile --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Bicep build failed" }
Write-Host "  Bicep compiled successfully" -ForegroundColor Green

# Step 5: What-If preview — shows the operator exactly which resources will
# be created, modified, or deleted before committing the change.
# AZ-104: 'az deployment sub what-if' is the subscription-scope equivalent of
# 'az deployment group what-if'. It calls the ARM What-If API, which evaluates
# the template against current subscription state and returns a diff.
# FullResourcePayloads mode returns the complete before/after resource payload
# (not just the changed properties) — useful for auditing sensitive changes.
if (-not $SkipWhatIf) {
    Write-Host "[5/6] Running what-if preview..." -ForegroundColor Yellow
    az deployment sub what-if `
        --name $deploymentName `
        --location $Location `
        --template-file $templateFile `
        --parameters $paramFile `
        --result-format FullResourcePayloads

    Write-Host "`n" -NoNewline
    # Require an explicit 'y' to continue — any other input (including Enter)
    # cancels the deployment. This is a safety gate for production deployments.
    $continue = Read-Host "Review the changes above. Continue with deployment? (y/N)"
    if ($continue -ne 'y') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
} else {
    # -SkipWhatIf bypasses the interactive review. Appropriate for automated
    # pipelines where the diff review happens as part of a PR approval process.
    Write-Host "[5/6] Skipping what-if (--SkipWhatIf)" -ForegroundColor DarkYellow
}

# Step 6: Execute the deployment. 'az deployment sub create' submits the
# ARM template to the subscription scope. ARM processes the deployment
# asynchronously and streams progress via --verbose.
# AZ-104: Subscription-scope deployments are tracked under:
#   Azure Portal > Subscriptions > <sub> > Deployments
# If the deployment fails, the ARM error includes the operation ID needed
# to look up the specific resource that failed.
Write-Host "[6/6] Deploying to Azure..." -ForegroundColor Yellow
$startTime = Get-Date

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters $paramFile `
    --verbose

# Check the exit code of the az CLI command. A non-zero exit code means
# ARM returned a failure response — the deployment did not complete
# successfully. The ARM portal link in the error message identifies
# which resource or module failed.
if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed. Check Azure Portal > Deployments for details."
}

# Calculate and display total wall-clock time for the deployment.
# Full infrastructure deployments typically take 20-45 minutes.
$duration = (Get-Date) - $startTime

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Deployment Succeeded!" -ForegroundColor Green
Write-Host "  Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# Retrieve and display the template's output values from the completed
# deployment. Outputs include resource names and addresses that downstream
# scripts (entra-setup.ps1, storage-operations.ps1) need to operate.
# AZ-104: Deployment outputs are stored in ARM and accessible even after the
# script exits — retrieve them with 'az deployment sub show'.
Write-Host "Key Outputs:" -ForegroundColor Cyan
az deployment sub show `
    --name $deploymentName `
    --query "properties.outputs" `
    --output table
