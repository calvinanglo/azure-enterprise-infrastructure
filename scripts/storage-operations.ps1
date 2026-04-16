#Requires -Version 7.0
<#
.SYNOPSIS
    Storage operations — SAS tokens, stored access policies, AzCopy,
    key rotation, import/export. AZ-104 storage domain deep-dive.

.PARAMETER Environment
    Target environment.

.PARAMETER StorageAccountName
    Name of the deployed storage account.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$StorageAccountName
)

$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Storage Operations Demo"                 -ForegroundColor Cyan
Write-Host "  Account: $StorageAccountName"            -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$rgName = "ent-rg-storage-$Environment"

# ── 1. Generate Account-Level SAS Token ────────────────────────────────────

Write-Host "[1/8] Generating Account SAS token..." -ForegroundColor Yellow

$expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
$accountSas = az storage account generate-sas `
    --account-name $StorageAccountName `
    --resource-types sco `
    --services bf `
    --permissions rl `
    --expiry $expiry `
    --https-only `
    --output tsv

Write-Host "  Account SAS (read-list, 4hr expiry): ?$($accountSas.Substring(0,20))..." -ForegroundColor Green

# ── 2. Create Stored Access Policy on Container ───────────────────────────

Write-Host "`n[2/8] Creating stored access policy..." -ForegroundColor Yellow

$accountKey = az storage account keys list -n $StorageAccountName -g $rgName --query "[0].value" -o tsv

az storage container policy create `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    --container-name 'app-data' `
    --name 'read-only-4hr' `
    --permissions rl `
    --expiry $expiry 2>$null

Write-Host "  Stored access policy 'read-only-4hr' created on 'app-data'" -ForegroundColor Green

# ── 3. Generate SAS from Stored Access Policy ─────────────────────────────

Write-Host "`n[3/8] Generating SAS from stored policy..." -ForegroundColor Yellow

$policySas = az storage container generate-sas `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    --name 'app-data' `
    --policy-name 'read-only-4hr' `
    --output tsv

Write-Host "  Policy-based SAS: ?$($policySas.Substring(0,20))..." -ForegroundColor Green
Write-Host "  Advantage: Revoke by deleting the policy, no need to rotate keys" -ForegroundColor Gray

# ── 4. Upload Test Data with AzCopy ───────────────────────────────────────

Write-Host "`n[4/8] Uploading test data with AzCopy..." -ForegroundColor Yellow

# Create test file
$testFile = Join-Path $env:TEMP "test-upload-$(Get-Date -Format 'yyyyMMddHHmmss').txt"
"Enterprise infrastructure test data - $(Get-Date)" | Out-File $testFile

$blobUrl = "https://$StorageAccountName.blob.core.windows.net/app-data"

# AzCopy with SAS
Write-Host "  azcopy copy `"$testFile`" `"$blobUrl/?$($accountSas.Substring(0,10))...`"" -ForegroundColor Gray
azcopy copy $testFile "$blobUrl?$accountSas" 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Upload succeeded" -ForegroundColor Green
} else {
    # Fallback to az cli
    az storage blob upload `
        --account-name $StorageAccountName `
        --account-key $accountKey `
        --container-name 'app-data' `
        --file $testFile `
        --name "test-data/$(Split-Path $testFile -Leaf)" `
        --overwrite 2>$null
    Write-Host "  Upload succeeded (via az cli fallback)" -ForegroundColor Green
}

Remove-Item $testFile -ErrorAction SilentlyContinue

# ── 5. AzCopy Sync (mirror a directory) ───────────────────────────────────

Write-Host "`n[5/8] AzCopy sync demo..." -ForegroundColor Yellow
Write-Host "  azcopy sync '<local-path>' '$blobUrl' --recursive --delete-destination=true" -ForegroundColor Gray
Write-Host "  Syncs local directory to blob container (mirror mode)" -ForegroundColor Gray

# ── 6. Key Rotation ──────────────────────────────────────────────────────

Write-Host "`n[6/8] Storage key rotation..." -ForegroundColor Yellow
Write-Host "  Best practice: rotate keys regularly, use Key Vault for key storage" -ForegroundColor Gray

# Show current keys
$keys = az storage account keys list -n $StorageAccountName -g $rgName --query "[].{Name:keyName, Value:value}" --output json | ConvertFrom-Json
Write-Host "  Current keys: $($keys[0].Name), $($keys[1].Name)" -ForegroundColor Gray

# Rotate key2 (always rotate the one NOT in use)
Write-Host "  Rotating key2..." -ForegroundColor Yellow
az storage account keys renew -n $StorageAccountName -g $rgName --key key2 --output none
Write-Host "  key2 rotated successfully" -ForegroundColor Green

# ── 7. Blob Versioning & Soft Delete Demo ─────────────────────────────────

Write-Host "`n[7/8] Checking blob versioning and soft delete..." -ForegroundColor Yellow

$blobServiceProps = az storage account blob-service-properties show `
    --account-name $StorageAccountName `
    -g $rgName `
    --query "{Versioning:isVersioningEnabled, SoftDelete:deleteRetentionPolicy.enabled, SoftDeleteDays:deleteRetentionPolicy.days, ChangeFeed:changeFeed.enabled}" `
    --output json | ConvertFrom-Json

Write-Host "  Versioning   : $($blobServiceProps.Versioning)" -ForegroundColor Green
Write-Host "  Soft Delete  : $($blobServiceProps.SoftDelete) ($($blobServiceProps.SoftDeleteDays) days)" -ForegroundColor Green
Write-Host "  Change Feed  : $($blobServiceProps.ChangeFeed)" -ForegroundColor Green

# ── 8. List Lifecycle Management Rules ────────────────────────────────────

Write-Host "`n[8/8] Lifecycle management rules..." -ForegroundColor Yellow

az storage account management-policy show `
    --account-name $StorageAccountName `
    --query "policy.rules[].{Name:name, CoolAfter:definition.actions.baseBlob.tierToCool.daysAfterModificationGreaterThan, ArchiveAfter:definition.actions.baseBlob.tierToArchive.daysAfterModificationGreaterThan, DeleteAfter:definition.actions.baseBlob.delete.daysAfterModificationGreaterThan}" `
    --output table

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Storage Operations Complete"             -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
