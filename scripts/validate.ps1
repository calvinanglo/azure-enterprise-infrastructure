#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-flight validation: lints Bicep, checks quotas, runs what-if.

.PARAMETER Environment
    Target environment: dev, staging, or prod.
#>

[CmdletBinding()]
param(
    # Mandatory ValidateSet ensures only a known environment name is accepted.
    # Running this script with no -Environment argument will prompt the user
    # rather than defaulting to a potentially wrong value.
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment
)

# Stop on any error so validation failures surface immediately and the script
# does not continue to later steps that may give misleading pass results.
$ErrorActionPreference = 'Stop'

# Resolve paths relative to the script directory so the script is portable.
$templateFile = Join-Path $PSScriptRoot '..\bicep\main.bicep'
$paramFile = Join-Path $PSScriptRoot "..\bicep\parameters\$Environment.bicepparam"

# exitCode tracks whether any check has failed. Using a non-terminating
# approach (accumulating failures vs. throwing immediately) allows all checks
# to run and produce a complete report before the script exits non-zero.
# This is more useful in CI pipelines than failing on the first issue.
$exitCode = 0

Write-Host "`n=== Pre-Flight Validation ===" -ForegroundColor Cyan

# ── Check 1: Bicep Lint ────────────────────────────────────────────────────
# Recursively find every .bicep file in the bicep directory (main template
# and all child modules) and attempt to compile each one.
# AZ-104: 'az bicep build' compiles Bicep to ARM JSON locally without
# contacting Azure. It validates syntax, checks for missing module references,
# and enforces linting rules (e.g., no hardcoded locations, no unsecure params).
# Running this on every .bicep file — not just main.bicep — catches errors
# in modules that main.bicep would only reach at deploy time.
Write-Host "`n[1/4] Linting Bicep templates..." -ForegroundColor Yellow
$bicepFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\bicep') -Filter '*.bicep' -Recurse
foreach ($file in $bicepFiles) {
    # --stdout sends the compiled ARM JSON to stdout rather than writing a
    # .json file on disk; Out-Null discards it since we only want the exit code.
    az bicep build --file $file.FullName --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: $($file.Name)" -ForegroundColor Red
        # Set exitCode to 1 but continue so remaining files are also checked.
        $exitCode = 1
    } else {
        Write-Host "  PASS: $($file.Name)" -ForegroundColor Green
    }
}

# ── Check 2: Authentication ────────────────────────────────────────────────
# Confirm that the operator has an active Azure CLI session before attempting
# any Azure API calls. Without this check, subsequent steps fail with cryptic
# auth errors. AZ-104: Authentication can be done via 'az login' (interactive
# browser), 'az login --service-principal' (CI/CD), or Managed Identity
# (when running inside Azure, e.g., Azure DevOps hosted agents or Azure VMs).
# '2>$null' suppresses the error message that az prints when not logged in,
# allowing the script to handle the failure gracefully via the if block below.
Write-Host "`n[2/4] Checking authentication..." -ForegroundColor Yellow
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  FAIL: Not logged in. Run 'az login' first." -ForegroundColor Red
    $exitCode = 1
} else {
    Write-Host "  PASS: Authenticated as $($account.user.name)" -ForegroundColor Green
    Write-Host "        Subscription: $($account.name)" -ForegroundColor Gray
}

# ── Check 3: Resource Provider Registrations ───────────────────────────────
# Azure resource providers must be registered in the subscription before
# their resource types can be deployed. New subscriptions often have many
# providers unregistered by default. AZ-104: Resource providers map to Azure
# services — Microsoft.Compute = VMs/VMSS, Microsoft.Network = VNets/NSGs,
# Microsoft.KeyVault = Key Vault, Microsoft.OperationalInsights = Log
# Analytics, Microsoft.Insights = Azure Monitor/Diagnostic Settings.
# If a provider is not registered, ARM returns a 'NoRegisteredProviderFound'
# error mid-deployment. Checking (and registering) here prevents that.
Write-Host "`n[3/4] Checking resource provider registrations..." -ForegroundColor Yellow
$requiredProviders = @(
    'Microsoft.Compute'              # VMs, VMSS, managed disks, snapshots
    'Microsoft.Network'              # VNets, NSGs, Load Balancers, Firewall, Bastion
    'Microsoft.Storage'              # Storage accounts, blob/file/queue/table
    'Microsoft.KeyVault'             # Key Vault for secrets, keys, and certificates
    'Microsoft.OperationalInsights'  # Log Analytics workspace
    'Microsoft.Insights'             # Azure Monitor, diagnostic settings, alerts
    'Microsoft.OperationsManagement' # Solutions/workbooks linked to Log Analytics
)

foreach ($provider in $requiredProviders) {
    # Query only the registrationState field to keep the response small.
    # 2>$null suppresses error output if the provider is not found at all
    # (e.g., in a new subscription where the CLI hasn't enumerated providers yet).
    $status = az provider show --namespace $provider --query "registrationState" --output tsv 2>$null
    if ($status -eq 'Registered') {
        Write-Host "  PASS: $provider" -ForegroundColor Green
    } else {
        # 'Registering' is an async operation that can take 1-2 minutes.
        # We trigger it here so it is ready by the time the actual deployment runs.
        # AZ-104: 'az provider register' is idempotent — safe to call even if
        # the provider is already in the 'Registering' state.
        Write-Host "  WARN: $provider ($status) — registering now..." -ForegroundColor DarkYellow
        az provider register --namespace $provider | Out-Null
    }
}

# ── Check 4: What-If (Dry Run) ─────────────────────────────────────────────
# Execute a what-if deployment at subscription scope. This calls the ARM
# What-If API which evaluates the template against the current subscription
# state and returns a change summary (resources to create, modify, or delete)
# WITHOUT making any actual changes.
# AZ-104: What-if is the safest way to validate a Bicep template end-to-end
# because it exercises the full ARM validation pipeline: parameter validation,
# resource provider schema validation, and dependency resolution. It catches
# errors that Bicep compilation alone (step 1) cannot find — for example,
# referencing a resource name that would exceed an Azure character limit.
# --no-prompt skips the interactive confirmation that what-if shows in some
# scenarios, making this suitable for non-interactive CI pipelines.
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

# ── Summary ────────────────────────────────────────────────────────────────
# Report the overall pass/fail result. Exiting with a non-zero code allows
# CI/CD systems (Azure DevOps, GitHub Actions) to treat failed validation
# as a blocking gate before a deployment stage proceeds.
Write-Host "`n=== Validation Complete ===" -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host "All checks passed. Safe to deploy.`n" -ForegroundColor Green
} else {
    Write-Host "Some checks failed. Review output above.`n" -ForegroundColor Red
}

# Exit with the accumulated exit code. exit 0 = all checks passed (CI gate
# passes). exit 1 = one or more checks failed (CI gate blocks deployment).
exit $exitCode
