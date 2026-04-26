# ============================================================================
# setup-management-group.ps1
# Creates a 2-tier Management Group hierarchy and moves the subscription into
# the prod child MG.
#
# AZ-104 Domain: Manage Azure identities and governance
# Management Groups (MGs) are containers above subscriptions in the Azure
# resource hierarchy. They enable inherited RBAC, Azure Policy, and cost
# rollup across many subscriptions. Tenant root MG always exists and is the
# parent of all customer MGs.
# ============================================================================

param(
    [Parameter(Mandatory = $false)][string]$RootMgName = 'ent-mg-root',
    [Parameter(Mandatory = $false)][string]$ProdMgName = 'ent-mg-prod',
    [Parameter(Mandatory = $false)][string]$RootMgDisplayName = 'Enterprise Root',
    [Parameter(Mandatory = $false)][string]$ProdMgDisplayName = 'Enterprise Production',
    [Parameter(Mandatory = $true)][string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

Write-Host "Creating root Management Group: $RootMgName"
# Create the root MG under the tenant root MG. The tenant root MG is implicit
# and has the same ID as the tenant. --name is the unique MG identifier
# (immutable); --display-name is the human-friendly label shown in the portal.
az account management-group create `
    --name $RootMgName `
    --display-name $RootMgDisplayName `
    --output none

Write-Host "Creating child Management Group: $ProdMgName (under $RootMgName)"
# Create the prod child MG with the root MG as its parent. --parent specifies
# the parent MG by name; without it the new MG is created directly under the
# tenant root MG.
az account management-group create `
    --name $ProdMgName `
    --display-name $ProdMgDisplayName `
    --parent $RootMgName `
    --output none

Write-Host "Moving subscription $SubscriptionId into $ProdMgName"
# Move the subscription into the prod child MG. The subscription must not
# already be a member of another MG (other than the tenant root). If it is,
# the move will fail with "subscription is already a member of MG X" — in
# that case use 'az account management-group subscription remove' first.
az account management-group subscription add `
    --name $ProdMgName `
    --subscription $SubscriptionId `
    --output none

Write-Host ""
Write-Host "Hierarchy:"
# Display the resulting hierarchy as a tree so the operator can verify the
# subscription is now nested correctly under prod → root → tenant root.
az account management-group show `
    --name $RootMgName `
    --expand `
    --recurse `
    --output table

Write-Host ""
Write-Host "Done. Re-target Azure Policy assignments to '$ProdMgName' scope to enforce policies subscription-wide via inheritance."
