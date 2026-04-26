# ============================================================================
# enable-disk-encryption.ps1
# Enables Azure Disk Encryption (ADE) on a managed disk attached to a VM,
# wrapping the data encryption key with a Key Encryption Key (KEK) stored
# in Azure Key Vault.
#
# AZ-104 Domain: Implement and manage storage / Deploy and manage compute
# ADE uses BitLocker (Windows) or DM-Crypt (Linux) inside the guest OS to
# encrypt the OS and data volumes at rest. The volume encryption key (VEK)
# is wrapped by the KEK in Key Vault, providing a hardware-rooted key
# hierarchy and BYOK (Bring Your Own Key) compliance posture.
#
# Prereq: VM must be running, Key Vault must have enabledForDiskEncryption=true
# and be in the same region as the VM. ADE is not supported on Basic-tier VMs
# or on Ephemeral OS disks.
# ============================================================================

param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$VmName,
    [Parameter(Mandatory = $true)][string]$KeyVaultName,
    [Parameter(Mandatory = $false)][string]$KekName = 'ent-kek-vmdisk-prod'
)

$ErrorActionPreference = 'Stop'

# Step 1 — Resolve Key Vault details. ADE needs the vault name, vault
# resource ID, and the URL of the KEK inside the vault.
Write-Host "Resolving Key Vault: $KeyVaultName"
$kv = az keyvault show --name $KeyVaultName --query "{id:id, vaultUri:properties.vaultUri}" -o json | ConvertFrom-Json
if (-not $kv) { throw "Key Vault not found: $KeyVaultName" }

# Step 2 — Create the KEK if it doesn't exist. RSA 2048 is the minimum size
# for Azure-supported KEKs; 3072 / 4096 are also supported.
Write-Host "Ensuring KEK exists: $KekName"
$existing = az keyvault key show --vault-name $KeyVaultName --name $KekName -o json 2>$null
if (-not $existing) {
    Write-Host "Creating new KEK..."
    az keyvault key create `
        --vault-name $KeyVaultName `
        --name $KekName `
        --kty RSA `
        --size 2048 `
        --ops wrapKey unwrapKey `
        --output none
} else {
    Write-Host "KEK already exists; reusing."
}
$kekKid = az keyvault key show --vault-name $KeyVaultName --name $KekName --query "key.kid" -o tsv

# Step 3 — Enable encryption on the VM. The az vm encryption enable command
# installs the ADE extension (AzureDiskEncryption for Linux,
# AzureDiskEncryptionForWindows for Windows) and triggers the encryption
# job. --volume-type All encrypts both OS and data disks.
Write-Host "Enabling ADE on VM: $VmName (this can take 15-30 min)"
az vm encryption enable `
    --resource-group $ResourceGroup `
    --name $VmName `
    --disk-encryption-keyvault $kv.id `
    --key-encryption-key $kekKid `
    --key-encryption-keyvault $kv.id `
    --volume-type All `
    --output none

# Step 4 — Poll status until encryption completes or 30 min elapses. The
# command returns immediately, but actual encryption runs as a background
# job inside the VM. The OsVolume / DataVolume EncryptionStatus fields
# transition from 'NotEncrypted' → 'EncryptionInProgress' → 'Encrypted'.
Write-Host "Polling encryption status..."
$timeoutMin = 30
$start = Get-Date
do {
    Start-Sleep -Seconds 30
    $status = az vm encryption show --resource-group $ResourceGroup --name $VmName -o json | ConvertFrom-Json
    Write-Host "  OS: $($status.disks[0].statuses[0].displayStatus)"
    if (((Get-Date) - $start).TotalMinutes -gt $timeoutMin) {
        Write-Warning "Timeout waiting for encryption; check portal for progress."
        break
    }
} while ($status.disks[0].statuses[0].code -notlike 'EncryptionState/encrypted')

Write-Host ""
Write-Host "ADE enabled. Verify in portal: VM → Disks → encryption column shows 'Customer-Managed (Azure)'."
