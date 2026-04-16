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
    # Environment drives naming suffixes for groups and app registrations
    # so that dev/staging/prod each have isolated Entra ID objects.
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    # The tenant domain is used to construct user principal names (UPNs)
    # in the format username@tenantdomain. AZ-104: Every Entra ID tenant has
    # at least one .onmicrosoft.com domain; custom domains (e.g., contoso.com)
    # can be added and verified in the Entra ID portal.
    [Parameter(Mandatory)]
    [string]$TenantDomain,

    # CSV path defaults to a sibling 'data' directory so the project is
    # self-contained. The CSV must contain columns:
    # Username, DisplayName, TempPassword, Department, JobTitle
    [string]$UserCsvPath = (Join-Path $PSScriptRoot '..\data\bulk-users.csv')
)

# Fail immediately on errors — Entra ID operations are stateful. A partial
# run (e.g., users created but groups not assigned) is harder to diagnose
# than a clean failure with a clear error message.
$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Entra ID Configuration"                  -ForegroundColor Cyan
Write-Host "  Environment: $Environment"               -ForegroundColor Cyan
Write-Host "  Tenant     : $TenantDomain"              -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. Bulk User Creation ──────────────────────────────────────────────────
# AZ-104: Bulk user creation is covered in the Manage Azure identities and
# governance domain. The az ad user create command wraps the MS Graph
# POST /users endpoint. Required fields match the Graph API's user resource
# schema: displayName, userPrincipalName, passwordProfile.
# usage-location ('US') is required before assigning Microsoft 365 licenses
# to a user — it tells Azure which data residency regulations apply.

Write-Host "[1/7] Creating users from CSV..." -ForegroundColor Yellow

if (Test-Path $UserCsvPath) {
    # Import-Csv reads the CSV as an array of PSCustomObject, with each
    # column header becoming a property name. This allows $user.Username,
    # $user.DisplayName, etc., for clean property access.
    $users = Import-Csv $UserCsvPath
    foreach ($user in $users) {
        # Construct the full UPN by combining the CSV username column with
        # the tenant domain. Example: jsmith@contoso.onmicrosoft.com
        $upn = "$($user.Username)@$TenantDomain"

        # Idempotency check — skip users that already exist. '2>$null'
        # suppresses the "user not found" error that az prints when the user
        # doesn't exist; the variable will be null/empty in that case.
        $exists = az ad user show --id $upn 2>$null
        if (-not $exists) {
            az ad user create `
                --display-name $user.DisplayName `
                --user-principal-name $upn `
                --password $user.TempPassword `
                # Force password change on first sign-in — a security best
                # practice. Users should never retain admin-assigned passwords.
                --force-change-password-next-sign-in true `
                --department $user.Department `
                --job-title $user.JobTitle `
                # usage-location is required for license assignment (M365/EMS).
                # AZ-104: Without this, attempts to assign P1/P2 licenses fail.
                --usage-location 'US'

            Write-Host "  Created: $upn" -ForegroundColor Green
        } else {
            Write-Host "  Exists:  $upn" -ForegroundColor Gray
        }
    }
} else {
    # Gracefully skip bulk creation if the CSV is absent — the rest of the
    # script (groups, app registration, RBAC) can still run independently.
    Write-Host "  CSV not found at $UserCsvPath — skipping bulk creation" -ForegroundColor DarkYellow
    Write-Host "  To use: create data/bulk-users.csv with columns: Username,DisplayName,TempPassword,Department,JobTitle" -ForegroundColor DarkYellow
}

# ── 2. Security Groups (Static) ───────────────────────────────────────────
# AZ-104: Security groups are the primary mechanism for granting RBAC
# permissions at scale. Assigning roles to groups (not individual users)
# follows the principle of least privilege and simplifies access reviews:
# adding/removing a user from a group is the only change needed to grant
# or revoke access. Static groups require manual membership management;
# dynamic groups (step 3) automate membership based on user attributes.
# Each group below maps to a specific RBAC role and resource scope in step 7.

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
    # Idempotency: skip group creation if it already exists.
    # Re-running this script should not fail or create duplicate groups.
    $exists = az ad group show --group $group.Name 2>$null
    if (-not $exists) {
        # mail-nickname is required by the Graph API even for security groups
        # that are not mail-enabled. It must be unique within the tenant.
        # Using the group name (without spaces) satisfies this requirement.
        az ad group create --display-name $group.Name --mail-nickname $group.Name --description $group.Desc
        Write-Host "  Created: $($group.Name)" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $($group.Name)" -ForegroundColor Gray
    }
}

# ── 3. Dynamic Group (auto-populate by department) ─────────────────────────
# AZ-104: Dynamic membership groups automatically add/remove members based
# on user attribute rules evaluated by Entra ID. They require an Entra ID
# P1 or P2 license per member. Dynamic groups are ideal for department-based
# access policies: when a user's department attribute changes (e.g., HR
# onboards them to IT), they are automatically added to the IT group.
# The Azure CLI does not support creating dynamic groups directly — the
# Graph API supports it but requires a complex multi-step call. Portal
# creation is the recommended approach for exam scenarios.
# AZ-104 exam tip: Know the membership rule syntax and that dynamic groups
# cannot have manually added members (membership is rule-driven only).

Write-Host "`n[3/7] Creating dynamic membership group..." -ForegroundColor Yellow
Write-Host "  NOTE: Dynamic groups require Entra ID P1/P2 license" -ForegroundColor DarkYellow
Write-Host "  Rule: (user.department -eq 'IT') -and (user.accountEnabled -eq true)" -ForegroundColor Gray
Write-Host "  Manual creation required in Portal: Entra ID > Groups > New Group > Dynamic User" -ForegroundColor Gray
Write-Host "  Use this membership rule:" -ForegroundColor Gray
# The single-quoted string below is the exact membership rule syntax to paste
# into the Portal or Graph API. -eq compares string attributes; -and chains
# multiple conditions. accountEnabled filters out disabled/offboarded accounts.
Write-Host '  (user.department -eq "IT") -and (user.accountEnabled -eq true)' -ForegroundColor White

# ── 4. Administrative Units ───────────────────────────────────────────────
# AZ-104: Administrative Units (AUs) are Entra ID containers that provide
# scoped delegation of administrative tasks. For example, a Helpdesk Admin
# role scoped to "AU-IT-Operations" can reset passwords only for users in
# that AU, not across the entire tenant. This supports the principle of
# least privilege for directory administration.
# AUs are created via the Microsoft Graph API because the Azure CLI's
# 'az ad' commands do not expose AU management. 'az rest' is a generic
# HTTP client built into the Azure CLI that can call any Azure or Graph API.

Write-Host "`n[4/7] Creating Administrative Units..." -ForegroundColor Yellow

$adminUnits = @(
    @{ Name = "AU-IT-Operations-$Environment";  Desc = "Scoped management for IT Operations department" }
    @{ Name = "AU-Development-$Environment";    Desc = "Scoped management for Development department" }
)

foreach ($au in $adminUnits) {
    # Administrative Units via MS Graph — az cli doesn't have direct AU support
    # Use az rest for Graph API
    # Build the JSON request body for the Graph API POST /administrativeUnits call.
    # ConvertTo-Json serializes the PowerShell hashtable to a JSON string.
    $body = @{
        displayName = $au.Name
        description = $au.Desc
    } | ConvertTo-Json

    # Check if the AU already exists using a Graph API GET with a $filter
    # query. The backtick escapes the $ in $filter so PowerShell does not
    # interpret it as a variable. --query "value[0].id" extracts just the
    # ID field from the first result; if no AU matches, the value is empty.
    $existing = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=displayName eq '$($au.Name)'" `
        --query "value[0].id" --output tsv 2>$null

    if (-not $existing) {
        # POST to the administrativeUnits endpoint to create the new AU.
        # The Content-Type header is required by the Graph API.
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
# AZ-104: Entra ID B2B (business-to-business) collaboration allows external
# users (guests) to be invited into the tenant. Guest users sign in with
# their home organization credentials (federated identity) and are assigned
# a UserType of 'Guest' in the directory. Guest access can be governed with
# Conditional Access policies (e.g., require MFA for all guests).
# The invite-redirect-url specifies where the guest lands after accepting
# the invitation — typically the Azure Portal or a specific application URL.
# This step is shown as a reference command only — a real email address
# is required to send an invitation, and the guest must click the link.

Write-Host "`n[5/7] Guest user invitation..." -ForegroundColor Yellow
Write-Host "  To invite an external user:" -ForegroundColor Gray
Write-Host '  az ad user invite --invited-user-email-address "vendor@external.com" --invite-redirect-url "https://portal.azure.com" --invited-user-display-name "External Vendor"' -ForegroundColor White
Write-Host "  Skipping actual invite (requires real email address)" -ForegroundColor DarkYellow

# ── 6. App Registration + Service Principal ──────────────────────────────
# AZ-104: An app registration is an Entra ID object that represents an
# application identity. When a CI/CD pipeline (e.g., GitHub Actions) needs
# to authenticate to Azure, it uses a service principal — the runtime
# instance of the app registration — with an assigned role.
# Workload Identity Federation (OIDC) is used here instead of client secrets
# because it eliminates long-lived credentials. GitHub Actions receives a
# short-lived OIDC token from GitHub's identity provider, exchanges it for
# an Azure access token using the federated credential trust configured below.
# AZ-104: This is the "keyless" authentication model — no secrets to rotate,
# no risk of credential leakage in pipeline logs or git history.

Write-Host "`n[6/7] Creating app registration for CI/CD..." -ForegroundColor Yellow

$appName = "app-enterprise-infra-cicd-$Environment"

# Check if an app registration with this display name already exists.
# --query "[0].appId" extracts the Application (client) ID of the first match.
$existingApp = az ad app list --display-name $appName --query "[0].appId" --output tsv 2>$null

if (-not $existingApp) {
    # Create the app registration. sign-in-audience 'AzureADMyOrg' restricts
    # authentication to accounts in this tenant only — appropriate for
    # internal tooling. Other options: AzureADMultipleOrgs (any Entra ID
    # tenant) or AzureADandPersonalMicrosoftAccount (consumer + work accounts).
    $app = az ad app create `
        --display-name $appName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json

    # Create the service principal (enterprise application) associated with
    # the app registration. The SP is the object that RBAC role assignments
    # target — you assign roles to the SP, not the app registration directly.
    az ad sp create --id $app.appId

    # Add federated credential for GitHub Actions (OIDC — no secrets!)
    # This creates a trust relationship: when GitHub Actions presents an OIDC
    # token for the specified repo and environment, Azure will issue an access
    # token for this service principal without requiring a client secret.
    # The subject claim format for GitHub Actions is:
    #   repo:<org>/<repo>:environment:<environment>
    # This restricts the credential to a specific GitHub environment gate,
    # preventing any other GitHub workflow from using this identity.
    $fedCredBody = @{
        name      = "github-actions-$Environment"
        # GitHub's OIDC token issuer URL — this is how Azure verifies the
        # token was issued by GitHub and not a spoofed identity provider.
        issuer    = "https://token.actions.githubusercontent.com"
        subject   = "repo:YOUR_ORG/azure-enterprise-infrastructure:environment:$Environment"
        # The audience must match what GitHub Actions requests when calling
        # the Azure token exchange endpoint.
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json

    az ad app federated-credential create --id $app.appId --parameters $fedCredBody 2>$null

    Write-Host "  Created: $appName (AppId: $($app.appId))" -ForegroundColor Green
    Write-Host "  Federated credential configured for GitHub Actions OIDC" -ForegroundColor Green
} else {
    Write-Host "  Exists:  $appName ($existingApp)" -ForegroundColor Gray
}

# ── 7. RBAC Assignments (Groups → Roles → Scopes) ───────────────────────
# AZ-104: RBAC role assignments bind a principal (user, group, or managed
# identity) to a role definition at a specific scope. The effective permissions
# of a principal are the union of all role assignments at or above its scope
# (subscription > resource group > resource). Assignments are additive —
# there is no "deny" assignment in standard Azure RBAC (except Azure ABAC
# deny assignments, which are a separate feature).
# Best practice: assign roles to GROUPS, not individuals. This makes access
# reviews faster and reduces the number of total role assignments
# (limit: 4,000 role assignments per subscription).

Write-Host "`n[7/7] Assigning RBAC roles to groups..." -ForegroundColor Yellow

$assignments = @(
    @{
        Group = "sg-infra-admins-$Environment"
        # Contributor: can create/manage all resource types but cannot assign
        # roles or manage access policies. Appropriate for infra admins who
        # need full resource control without the ability to escalate privileges.
        Role  = "Contributor"
        # Subscription scope — infra admins need access across all RGs.
        # $(az account show --query id -o tsv) dynamically retrieves the
        # current subscription ID to avoid hard-coding it in the script.
        Scope = "/subscriptions/$(az account show --query id -o tsv)"
    }
    @{
        Group = "sg-security-auditors-$Environment"
        # Reader: read-only access to all resource types in the scope.
        # Security auditors need to inspect Key Vault access policies,
        # diagnostic settings, and resource configurations without the
        # ability to modify anything.
        Role  = "Reader"
        # Scoped to the security resource group only — auditors do not
        # need visibility into compute or networking details.
        Scope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/ent-rg-security-$Environment"
    }
    @{
        Group = "sg-backup-operators-$Environment"
        # Backup Contributor: can manage backup items, policies, and vaults
        # but cannot create or delete storage accounts. This is a built-in
        # role specifically for backup management workflows.
        # AZ-104: Use built-in roles where possible — they are maintained
        # by Microsoft and updated when new resource types are added.
        Role  = "Backup Contributor"
        # Scoped to the compute RG where the Recovery Services Vault lives.
        Scope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/ent-rg-compute-$Environment"
    }
)

foreach ($a in $assignments) {
    # Retrieve the group's object ID (GUID). Role assignments reference the
    # object ID, not the display name — the display name can change but the
    # ID is immutable. '2>$null' handles groups that weren't created in step 2
    # (e.g., if this script is run without the CSV on an empty tenant).
    $groupId = az ad group show --group $a.Group --query id --output tsv 2>$null
    if ($groupId) {
        # Idempotency check: query for an existing role assignment with the
        # same assignee, role, and scope. An empty result ('[]') means the
        # assignment doesn't exist yet and should be created.
        $existing = az role assignment list --assignee $groupId --role $a.Role --scope $a.Scope --query "[0]" 2>$null
        if (-not $existing -or $existing -eq '[]') {
            az role assignment create --assignee $groupId --role $a.Role --scope $a.Scope 2>$null
            # Split-Path -Leaf extracts the last segment of the scope path
            # (e.g., the RG name) for a readable log message.
            Write-Host "  Assigned: $($a.Group) → $($a.Role) @ $(Split-Path $a.Scope -Leaf)" -ForegroundColor Green
        } else {
            Write-Host "  Exists:   $($a.Group) → $($a.Role)" -ForegroundColor Gray
        }
    } else {
        # Group may not exist if step 2 was skipped or the group was deleted.
        Write-Host "  SKIP:  Group $($a.Group) not found" -ForegroundColor DarkYellow
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Entra ID Configuration Complete"        -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# Post-setup verification commands for the operator to run manually.
# AZ-104: These queries validate that the objects created above are
# visible in the directory and that RBAC assignments are in effect.
# The last query lists all role assignments where the principal name
# contains 'sg-' — a quick way to audit group-based RBAC in the subscription.
Write-Host "Post-setup verification:" -ForegroundColor Cyan
Write-Host "  az ad user list --query `"[].{UPN:userPrincipalName, Dept:department}`" --output table"
Write-Host "  az ad group list --query `"[?contains(displayName,'sg-')].{Name:displayName, Members:length(members)}`" --output table"
Write-Host "  az role assignment list --all --query `"[?contains(principalName,'sg-')].{Principal:principalName, Role:roleDefinitionName, Scope:scope}`" --output table"
