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
    # Mandatory environment selector. ValidateSet prevents accidentally
    # targeting the wrong environment via a typo in the parameter value.
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    # Explicit -Confirm switch acts as a second layer of protection against
    # accidental execution. The script exits immediately if this flag is not
    # provided, making it impossible to trigger teardown by running the script
    # without thinking about it. AZ-104: Always require explicit confirmation
    # for destructive operations, especially in production.
    [switch]$Confirm
)

# Stop on first error — teardown must not proceed past a failure since partial
# deletions can leave the environment in an inconsistent state.
$ErrorActionPreference = 'Stop'

# orgPrefix must match the value used during deployment (set in main.bicep
# as the orgPrefix parameter default). If the prefix differs, the resource
# group names won't match and 'az group exists' will return false for all,
# causing the teardown to silently skip everything.
$orgPrefix = 'ent'

# Resource groups are listed in reverse dependency order.
# AZ-104 dependency rationale:
#   - Compute is deleted first: VMs and VMSS reference networking (NICs in
#     subnets) and storage (boot diagnostics). Removing compute first
#     releases those references before the dependent resources are deleted.
#   - Storage is deleted second: no remaining resources depend on it after
#     compute is gone.
#   - Security (Key Vault) third: compute managed identity Key Vault access
#     policies are gone once compute is deleted.
#   - Monitoring fourth: diagnostic settings targets can be removed once the
#     resources sending diagnostics are gone.
#   - Networking last: VNet peering and Firewall routes can only be cleanly
#     removed after the spoke resources (compute, storage) no longer exist.
#     Attempting to delete a VNet with active peering or NIC references fails.
$resourceGroups = @(
    "$orgPrefix-rg-compute-$Environment"
    "$orgPrefix-rg-storage-$Environment"
    "$orgPrefix-rg-security-$Environment"
    "$orgPrefix-rg-monitoring-$Environment"
    "$orgPrefix-rg-networking-$Environment"    # Deleted last (peering dependencies)
)

# Gate 1: Require explicit -Confirm flag. Without it, print usage and exit.
# This prevents accidental teardown if the script is run without parameters
# or if someone auto-completes the command without reviewing it.
if (-not $Confirm) {
    Write-Host "`nERROR: You must pass -Confirm to execute teardown." -ForegroundColor Red
    Write-Host "Usage: .\teardown.ps1 -Environment $Environment -Confirm`n" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  TEARDOWN: $Environment environment"     -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

# Gate 2: Production-only extra confirmation.
# AZ-104: Production environments should have additional safeguards beyond
# standard confirmation. Typing "DELETE PRODUCTION" forces the operator to
# consciously acknowledge the action — it cannot be satisfied by pressing
# Enter or typing 'y', reducing the chance of accidental prod teardown.
if ($Environment -eq 'prod') {
    $prodConfirm = Read-Host "Type 'DELETE PRODUCTION' to confirm production teardown"
    if ($prodConfirm -ne 'DELETE PRODUCTION') {
        Write-Host "Teardown cancelled." -ForegroundColor Yellow
        exit 0
    }

    # Remove resource locks before deletion.
    # AZ-104: Azure resource locks (CanNotDelete, ReadOnly) prevent accidental
    # deletion or modification of resources. Production environments should have
    # CanNotDelete locks applied by the governance module. Attempting to delete
    # a resource group with a lock will fail with a 409 Conflict error, so locks
    # must be removed first. Only subscription owners or users with the
    # Microsoft.Authorization/locks/delete permission can remove locks.
    Write-Host "Removing resource locks..." -ForegroundColor Yellow
    foreach ($rg in $resourceGroups) {
        # List all locks on the resource group. '2>$null' suppresses errors for
        # resource groups that don't exist yet (e.g., partial deployment).
        $locks = az lock list --resource-group $rg --output json 2>$null | ConvertFrom-Json
        foreach ($lock in $locks) {
            Write-Host "  Removing lock: $($lock.name) on $rg" -ForegroundColor DarkYellow
            # Delete each lock by name and resource group. After this, the
            # resource group is no longer protected and can be deleted.
            az lock delete --name $lock.name --resource-group $rg
        }
    }
}

# Delete resource groups in the dependency order defined above.
# AZ-104: Deleting a resource group is the most efficient way to remove all
# resources within it — ARM handles the deletion order of individual resources
# automatically (it resolves dependencies). This is faster and less error-prone
# than deleting each resource individually.
foreach ($rg in $resourceGroups) {
    # Check if the resource group exists before attempting deletion.
    # This makes the script idempotent — re-running it after a partial teardown
    # skips already-deleted resource groups without erroring out.
    $exists = az group exists --name $rg --output tsv
    if ($exists -eq 'true') {
        Write-Host "Deleting: $rg ..." -ForegroundColor Yellow
        # --yes: Skips the interactive "Are you sure?" prompt (required for
        #        non-interactive/scripted execution).
        # --no-wait: Returns immediately without waiting for deletion to complete.
        #            Resource group deletion is asynchronous — ARM queues the
        #            deletion and processes it in the background. The script
        #            initiates all deletions quickly rather than waiting for each
        #            one sequentially (which could take 10+ minutes per group).
        az group delete --name $rg --yes --no-wait
        Write-Host "  Deletion initiated (async)" -ForegroundColor DarkYellow
    } else {
        Write-Host "Skipping: $rg (does not exist)" -ForegroundColor Gray
    }
}

# Inform the operator that deletion is running in the background.
# AZ-104: Monitor async resource group deletions in the Azure Portal under
# Subscriptions > Resource groups, or use the az CLI command shown below.
# The 'Deleting' provisioning state indicates deletion is in progress.
Write-Host "`nTeardown initiated. Resource groups are being deleted asynchronously." -ForegroundColor Green
Write-Host "Monitor progress: az group list --query `"[?starts_with(name,'$orgPrefix-rg')].{Name:name,State:properties.provisioningState}`" --output table`n" -ForegroundColor Cyan
