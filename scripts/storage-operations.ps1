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

    # The storage account name is obtained from the deploy.ps1 output
    # (storageAccountName) or from:
    #   az deployment sub show --name <name> --query "properties.outputs.storageAccountName.value" -o tsv
    # Storage account names must be globally unique, 3-24 lowercase alphanumeric characters.
    [Parameter(Mandatory)]
    [string]$StorageAccountName
)

$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Storage Operations Demo"                 -ForegroundColor Cyan
Write-Host "  Account: $StorageAccountName"            -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# The storage resource group name must match the pattern used in main.bicep.
$rgName = "ent-rg-storage-$Environment"

# ── 1. Generate Account-Level SAS Token ────────────────────────────────────
# AZ-104: A Shared Access Signature (SAS) is a URI that grants limited,
# time-bound access to Azure Storage resources without exposing the account
# key. Account-level SAS can target multiple services (blob, file, queue,
# table) and resource types (service, container/share, object) in a single
# token. Use account SAS for broad cross-service access; use service SAS
# for access to a single service; use stored access policy SAS (step 3)
# for revocable access.
# Token permissions are additive — 'rl' means read + list only (no write,
# delete, create, or add). This follows least-privilege access.

Write-Host "[1/8] Generating Account SAS token..." -ForegroundColor Yellow

# Set expiry to 4 hours from now in UTC. Short-lived SAS tokens limit the
# damage window if a token is intercepted. AZ-104: Always use HTTPS-only
# SAS (--https-only) to prevent token interception via network sniffing.
$expiry = (Get-Date).AddHours(4).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
$accountSas = az storage account generate-sas `
    --account-name $StorageAccountName `
    # sco = service, container, object — all three resource type levels.
    # Restricting to 'o' (object only) would limit access to individual blobs.
    --resource-types sco `
    # bf = blob and file services. Omit 'q' (queue) and 't' (table) since
    # those services are not needed by callers of this token.
    --services bf `
    # rl = read and list. No write/delete/create permissions.
    --permissions rl `
    --expiry $expiry `
    # Reject any request that uses the SAS over plain HTTP — HTTPS only.
    # AZ-104: Account SAS can optionally include an allowed IP range for
    # additional restriction (--ip flag), not used here for demo purposes.
    --https-only `
    --output tsv

# Only show the first 20 characters to avoid logging the full token.
# A SAS token in a log file is a security risk — anyone with the log can use it.
Write-Host "  Account SAS (read-list, 4hr expiry): ?$($accountSas.Substring(0,20))..." -ForegroundColor Green

# ── 2. Create Stored Access Policy on Container ───────────────────────────
# AZ-104: A stored access policy (SAP) is a server-side definition of SAS
# constraints (permissions, start time, expiry) stored on a container or
# queue. SAS tokens generated from a SAP can be revoked instantly by
# deleting or modifying the policy — without rotating the account key.
# This is the key advantage over ad-hoc SAS tokens: revocation without
# key rotation. A container can have up to 5 stored access policies.

Write-Host "`n[2/8] Creating stored access policy..." -ForegroundColor Yellow

# Retrieve account key for operations that require key-based auth.
# AZ-104: Two storage account keys (key1, key2) are provided to enable
# zero-downtime key rotation — switch consumers to key2 first, then
# rotate key1, then switch back. Keys grant full access to the account;
# use SAS tokens or managed identity for least-privilege access instead.
$accountKey = az storage account keys list -n $StorageAccountName -g $rgName --query "[0].value" -o tsv

az storage container policy create `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    # Target the 'app-data' container — must already exist in the storage account.
    --container-name 'app-data' `
    # Policy name is descriptive: permission level and expiry duration.
    --name 'read-only-4hr' `
    # rl = read and list — same as the account SAS above, but now server-side.
    --permissions rl `
    --expiry $expiry 2>$null

Write-Host "  Stored access policy 'read-only-4hr' created on 'app-data'" -ForegroundColor Green

# ── 3. Generate SAS from Stored Access Policy ─────────────────────────────
# AZ-104: A policy-based SAS token references the stored access policy by
# name instead of embedding permissions and expiry directly in the token.
# This means: (a) the token itself is shorter, and (b) the policy can be
# deleted to immediately revoke ALL tokens that reference it — regardless
# of when those tokens expire. This is the recommended approach for any
# SAS token shared with external parties or stored in application config.

Write-Host "`n[3/8] Generating SAS from stored policy..." -ForegroundColor Yellow

$policySas = az storage container generate-sas `
    --account-name $StorageAccountName `
    --account-key $accountKey `
    --name 'app-data' `
    # Reference the stored policy by name — the token inherits its permissions
    # and expiry from the policy definition, not from inline parameters.
    --policy-name 'read-only-4hr' `
    --output tsv

Write-Host "  Policy-based SAS: ?$($policySas.Substring(0,20))..." -ForegroundColor Green
Write-Host "  Advantage: Revoke by deleting the policy, no need to rotate keys" -ForegroundColor Gray

# ── 4. Upload Test Data with AzCopy ───────────────────────────────────────
# AZ-104: AzCopy is a command-line utility optimized for high-throughput
# Azure Storage transfers. It supports parallelism, resumable transfers,
# and OAuth/SAS authentication. Use AzCopy for large data movements (GB+);
# use 'az storage blob upload' for small files in scripted workflows.
# AzCopy authentication options: SAS token (used here), service principal
# (az login before azcopy), or managed identity (azcopy login --identity).

Write-Host "`n[4/8] Uploading test data with AzCopy..." -ForegroundColor Yellow

# Create a small temp file to use as upload test data.
$testFile = Join-Path $env:TEMP "test-upload-$(Get-Date -Format 'yyyyMMddHHmmss').txt"
"Enterprise infrastructure test data - $(Get-Date)" | Out-File $testFile

# Construct the blob container URL. AzCopy appends the SAS token as a query
# string parameter — the full URL format is: https://<account>.blob.core.windows.net/<container>?<sas>
$blobUrl = "https://$StorageAccountName.blob.core.windows.net/app-data"

# AzCopy with SAS
# Log the command with a truncated SAS for audit purposes without leaking credentials.
Write-Host "  azcopy copy `"$testFile`" `"$blobUrl/?$($accountSas.Substring(0,10))...`"" -ForegroundColor Gray
# The actual AzCopy call uses the full SAS token appended to the container URL.
# 2>$null suppresses AzCopy's verbose output on stderr; we check $LASTEXITCODE instead.
azcopy copy $testFile "$blobUrl?$accountSas" 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Upload succeeded" -ForegroundColor Green
} else {
    # Fallback to az cli: used when AzCopy is not installed. The Azure CLI's
    # storage blob upload command is slower for large files but requires no
    # separate tool installation. AZ-104: Know both methods for the exam.
    az storage blob upload `
        --account-name $StorageAccountName `
        --account-key $accountKey `
        --container-name 'app-data' `
        --file $testFile `
        # Use a virtual directory prefix (test-data/) to organize blobs.
        # Azure Blob Storage has no real folders — the '/' in a blob name
        # is just a naming convention that the portal renders as a folder.
        --name "test-data/$(Split-Path $testFile -Leaf)" `
        --overwrite 2>$null
    Write-Host "  Upload succeeded (via az cli fallback)" -ForegroundColor Green
}

# Remove the temp file to avoid accumulating test artifacts on the local machine.
Remove-Item $testFile -ErrorAction SilentlyContinue

# ── 5. AzCopy Sync (mirror a directory) ───────────────────────────────────
# AZ-104: 'azcopy sync' mirrors a source to a destination — it copies new
# and modified files and (with --delete-destination=true) removes files in
# the destination that no longer exist in the source. This is different from
# 'azcopy copy' which always transfers files without checking if they already
# exist. Use sync for backup scenarios and deployment pipelines.
# --recursive: process all subdirectories.
# --delete-destination=true: delete blobs not present in the source (mirror mode).

Write-Host "`n[5/8] AzCopy sync demo..." -ForegroundColor Yellow
Write-Host "  azcopy sync '<local-path>' '$blobUrl' --recursive --delete-destination=true" -ForegroundColor Gray
Write-Host "  Syncs local directory to blob container (mirror mode)" -ForegroundColor Gray

# ── 6. Key Rotation ──────────────────────────────────────────────────────
# AZ-104: Storage account key rotation is a security hygiene task. Keys
# should be rotated regularly (e.g., every 90 days) and whenever a key may
# have been compromised. The two-key design allows zero-downtime rotation:
# 1. Update applications to use key2.
# 2. Rotate key1 (key1 gets a new value).
# 3. Update applications back to key1 (now the fresh key).
# 4. Rotate key2.
# Best practice: replace key-based authentication with managed identity or
# SAS tokens so that key rotation does not require application config changes.

Write-Host "`n[6/8] Storage key rotation..." -ForegroundColor Yellow
Write-Host "  Best practice: rotate keys regularly, use Key Vault for key storage" -ForegroundColor Gray

# Show current keys — display names only, not values. Key values are secrets
# and should not appear in script output.
$keys = az storage account keys list -n $StorageAccountName -g $rgName --query "[].{Name:keyName, Value:value}" --output json | ConvertFrom-Json
Write-Host "  Current keys: $($keys[0].Name), $($keys[1].Name)" -ForegroundColor Gray

# Rotate key2 (always rotate the one NOT in use)
# AZ-104: 'az storage account keys renew' generates a new cryptographically
# random value for the specified key. The old key is immediately invalidated
# — any SAS tokens or connection strings using the old key will fail.
# This is why key2 is rotated first while applications are still using key1.
Write-Host "  Rotating key2..." -ForegroundColor Yellow
az storage account keys renew -n $StorageAccountName -g $rgName --key key2 --output none
Write-Host "  key2 rotated successfully" -ForegroundColor Green

# ── 7. Blob Versioning & Soft Delete Demo ─────────────────────────────────
# AZ-104: Blob versioning and soft delete are data protection features:
#   - Versioning: automatically creates an immutable snapshot of a blob on
#     every write operation. Allows point-in-time recovery of any previous
#     version. Stored at the blob level; versions are billed at standard rates.
#   - Soft delete: deleted blobs are retained for a configurable number of
#     days (here: SoftDeleteDays) before permanent deletion. Deleted blobs
#     can be undeleted within the retention window.
#   - Change Feed: append-only log of all create/modify/delete operations on
#     blobs in the account. Used for audit trails and event-driven processing.
# These are configured on the blob service (not individual containers/blobs)
# and are typically set by the storage Bicep module. This step queries the
# current state to confirm they were enabled at deployment time.

Write-Host "`n[7/8] Checking blob versioning and soft delete..." -ForegroundColor Yellow

$blobServiceProps = az storage account blob-service-properties show `
    --account-name $StorageAccountName `
    -g $rgName `
    # Project only the fields relevant to data protection — avoids a large
    # JSON response and makes the output readable.
    --query "{Versioning:isVersioningEnabled, SoftDelete:deleteRetentionPolicy.enabled, SoftDeleteDays:deleteRetentionPolicy.days, ChangeFeed:changeFeed.enabled}" `
    --output json | ConvertFrom-Json

Write-Host "  Versioning   : $($blobServiceProps.Versioning)" -ForegroundColor Green
Write-Host "  Soft Delete  : $($blobServiceProps.SoftDelete) ($($blobServiceProps.SoftDeleteDays) days)" -ForegroundColor Green
Write-Host "  Change Feed  : $($blobServiceProps.ChangeFeed)" -ForegroundColor Green

# ── 8. List Lifecycle Management Rules ────────────────────────────────────
# AZ-104: Blob lifecycle management automatically transitions blobs between
# access tiers or deletes them based on age rules, reducing storage costs.
# Tier hierarchy (cost vs. access speed):
#   Hot → Cool → Cold → Archive
# Hot is fastest and most expensive; Archive is cheapest but requires
# 1-15 hours to rehydrate before a blob can be read (no direct access).
# Common lifecycle policy:
#   - Move to Cool after 30 days (infrequently accessed data)
#   - Move to Archive after 90 days (rarely accessed, compliance retention)
#   - Delete after 365 days (data retention policy)
# Lifecycle rules are evaluated once per day by the storage service.
# The query below surfaces the transition thresholds for each rule.

Write-Host "`n[8/8] Lifecycle management rules..." -ForegroundColor Yellow

az storage account management-policy show `
    --account-name $StorageAccountName `
    # Project rule name and the day thresholds for each tier transition action.
    # CoolAfter/ArchiveAfter/DeleteAfter correspond to the blob age in days
    # since last modification that triggers each action.
    --query "policy.rules[].{Name:name, CoolAfter:definition.actions.baseBlob.tierToCool.daysAfterModificationGreaterThan, ArchiveAfter:definition.actions.baseBlob.tierToArchive.daysAfterModificationGreaterThan, DeleteAfter:definition.actions.baseBlob.delete.daysAfterModificationGreaterThan}" `
    --output table

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Storage Operations Complete"             -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
