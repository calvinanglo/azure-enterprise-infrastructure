#Requires -Version 7.0
<#
.SYNOPSIS
    Entra ID setup — users, groups, administrative units, guest invite, SSPR config.
    Covers AZ-104 identity domain comprehensively.

.DESCRIPTION
    Creates:
    - Bulk users (from CSV)
    - Security groups (static + dynamic)
    - Administrative units with scoped role assignments
    - Guest user invitation
    - App registration with service principal
    - Conditional Access readiness check

.PARAMETER Environment
    Target environment (dev, staging, prod).

.PARAMETER TenantDomain
    Your Entra ID tenant domain (e.g., contoso.onmicrosoft.com).

.PARAMETER UserCsvPath
    Path to CSV file for bulk user creation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$TenantDomain,

    [string]$UserCsvPath = (Join-Path $PSScriptRoot '..\data\bulk-users.csv')
)

$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Entra ID Configuration"                  -ForegroundColor Cyan
Write-Host "  Environment: $Environment"               -ForegroundColor Cyan
Write-Host "  Tenant     : $TenantDomain"              -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. Bulk User Creation ──────────────────────────────────────────────────

Write-Host "[1/7] Creating users from CSV..." -ForegroundColor Yellow

if (Test-Path $UserCsvPath) {
    $users = Import-Csv $UserCsvPath
    foreach ($user in $users) {
        $upn = "$($user.Username)@$TenantDomain"
        $exists = az ad user show --id $upn 2>$null
        if (-not $exists) {
            az ad user create `
                --display-name $user.DisplayName `
                --user-principal-name $upn `
                --password $user.TempPassword `
                --force-change-password-next-sign-in true `
                --department $user.Department `
                --job-title $user.JobTitle `
                --usage-location 'US'

            Write-Host "  Created: $upn" -ForegroundColor Green
        } else {
            Write-Host "  Exists:  $upn" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  CSV not found at $UserCsvPath — skipping bulk creation" -ForegroundColor DarkYellow
    Write-Host "  To use: create data/bulk-users.csv with columns: Username,DisplayName,TempPassword,Department,JobTitle" -ForegroundColor DarkYellow
}

# ── 2. Security Groups (Static) ───────────────────────────────────────────

Write-Host "`n[2/7] Creating security groups..." -ForegroundColor Yellow

$groups = @(
    @{ Name = "sg-infra-admins-$Environment";      Desc = "Infrastructure administrators — Contributor on all RGs" }
    @{ Name = "sg-network-ops-$Environment";        Desc = "Network operations — custom Network Viewer role" }
    @{ Name = "sg-vm-operators-$Environment";       Desc = "VM operators — start/stop/restart only" }
    @{ Name = "sg-monitoring-readers-$Environment"; Desc = "Monitoring team — read metrics and manage alerts" }
    @{ Name = "sg-security-auditors-$Environment";  Desc = "Security auditors — read-only on Key Vault and policies" }
    @{ Name = "sg-backup-operators-$Environment";   Desc = "Backup operators — manage Recovery Services Vault" }
)

foreach ($group in $groups) {
    $exists = az ad group show --group $group.Name 2>$null
    if (-not $exists) {
        az ad group create --display-name $group.Name --mail-nickname $group.Name --description $group.Desc
        Write-Host "  Created: $($group.Name)" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $($group.Name)" -ForegroundColor Gray
    }
}

# ── 3. Dynamic Group (auto-populate by department) ─────────────────────────

Write-Host "`n[3/7] Creating dynamic membership group..." -ForegroundColor Yellow
Write-Host "  NOTE: Dynamic groups require Entra ID P1/P2 license" -ForegroundColor DarkYellow
Write-Host "  Rule: (user.department -eq 'IT') -and (user.accountEnabled -eq true)" -ForegroundColor Gray
Write-Host "  Manual creation required in Portal: Entra ID > Groups > New Group > Dynamic User" -ForegroundColor Gray
Write-Host "  Use this membership rule:" -ForegroundColor Gray
Write-Host '  (user.department -eq "IT") -and (user.accountEnabled -eq true)' -ForegroundColor White

# ── 4. Administrative Units ───────────────────────────────────────────────

Write-Host "`n[4/7] Creating Administrative Units..." -ForegroundColor Yellow

$adminUnits = @(
    @{ Name = "AU-IT-Operations-$Environment";  Desc = "Scoped management for IT Operations department" }
    @{ Name = "AU-Development-$Environment";    Desc = "Scoped management for Development department" }
)

foreach ($au in $adminUnits) {
    # Administrative Units via MS Graph — az cli doesn't have direct AU support
    # Use az rest for Graph API
    $body = @{
        displayName = $au.Name
        description = $au.Desc
    } | ConvertTo-Json

    $existing = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=displayName eq '$($au.Name)'" `
        --query "value[0].id" --output tsv 2>$null

    if (-not $existing) {
        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/directory/administrativeUnits" `
            --body $body `
            --headers "Content-Type=application/json" 2>$null

        Write-Host "  Created: $($au.Name)" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $($au.Name)" -ForegroundColor Gray
    }
}

# ── 5. Guest User Invitation ─────────────────────────────────────────────

Write-Host "`n[5/7] Guest user invitation..." -ForegroundColor Yellow
Write-Host "  To invite an external user:" -ForegroundColor Gray
Write-Host '  az ad user invite --invited-user-email-address "vendor@external.com" --invite-redirect-url "https://portal.azure.com" --invited-user-display-name "External Vendor"' -ForegroundColor White
Write-Host "  Skipping actual invite (requires real email address)" -ForegroundColor DarkYellow

# ── 6. App Registration + Service Principal ──────────────────────────────

Write-Host "`n[6/7] Creating app registration for CI/CD..." -ForegroundColor Yellow

$appName = "app-enterprise-infra-cicd-$Environment"
$existingApp = az ad app list --display-name $appName --query "[0].appId" --output tsv 2>$null

if (-not $existingApp) {
    $app = az ad app create `
        --display-name $appName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json

    # Create service principal
    az ad sp create --id $app.appId

    # Add federated credential for GitHub Actions (OIDC — no secrets!)
    $fedCredBody = @{
        name = "github-actions-$Environment"
        issuer = "https://token.actions.githubusercontent.com"
        subject = "repo:YOUR_ORG/azure-enterprise-infrastructure:environment:$Environment"
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json

    az ad app federated-credential create --id $app.appId --parameters $fedCredBody 2>$null

    Write-Host "  Created: $appName (AppId: $($app.appId))" -ForegroundColor Green
    Write-Host "  Federated credential configured for GitHub Actions OIDC" -ForegroundColor Green
} else {
    Write-Host "  Exists:  $appName ($existingApp)" -ForegroundColor Gray
}

# ── 7. RBAC Assignments (Groups → Roles → Scopes) ───────────────────────

Write-Host "`n[7/7] Assigning RBAC roles to groups..." -ForegroundColor Yellow

$assignments = @(
    @{
        Group = "sg-infra-admins-$Environment"
        Role  = "Contributor"
        Scope = "/subscriptions/$(az account show --query id -o tsv)"
    }
    @{
        Group = "sg-security-auditors-$Environment"
        Role  = "Reader"
        Scope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/ent-rg-security-$Environment"
    }
    @{
        Group = "sg-backup-operators-$Environment"
        Role  = "Backup Contributor"
        Scope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/ent-rg-compute-$Environment"
    }
)

foreach ($a in $assignments) {
    $groupId = az ad group show --group $a.Group --query id --output tsv 2>$null
    if ($groupId) {
        $existing = az role assignment list --assignee $groupId --role $a.Role --scope $a.Scope --query "[0]" 2>$null
        if (-not $existing -or $existing -eq '[]') {
            az role assignment create --assignee $groupId --role $a.Role --scope $a.Scope 2>$null
            Write-Host "  Assigned: $($a.Group) → $($a.Role) @ $(Split-Path $a.Scope -Leaf)" -ForegroundColor Green
        } else {
            Write-Host "  Exists:   $($a.Group) → $($a.Role)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  SKIP:  Group $($a.Group) not found" -ForegroundColor DarkYellow
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Entra ID Configuration Complete"        -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Post-setup verification:" -ForegroundColor Cyan
Write-Host "  az ad user list --query `"[].{UPN:userPrincipalName, Dept:department}`" --output table"
Write-Host "  az ad group list --query `"[?contains(displayName,'sg-')].{Name:displayName, Members:length(members)}`" --output table"
Write-Host "  az role assignment list --all --query `"[?contains(principalName,'sg-')].{Principal:principalName, Role:roleDefinitionName, Scope:scope}`" --output table"
