# ============================================================================
# configure-conditional-access.ps1
# Creates an Entra ID Conditional Access policy requiring MFA when admin
# role members access the Azure Portal from outside trusted IP ranges.
#
# AZ-104 Domain: Manage Azure identities and governance
# Conditional Access (CA) is Entra ID's policy engine for runtime access
# decisions. Policies evaluate signals (user, device, location, app, risk)
# and apply controls (require MFA, block, require compliant device).
#
# Prereq: Microsoft.Graph PowerShell module installed and signed in with a
# user holding the Conditional Access Administrator or Global Administrator
# role. Install with: Install-Module Microsoft.Graph -Scope CurrentUser
# ============================================================================

param(
    [Parameter(Mandatory = $false)][string]$PolicyName = 'ent-ca-mfa-untrusted-locations',
    # CIDR blocks treated as trusted (no MFA prompt). Default is corporate
    # office WAN ranges — replace with your real trusted IP set before use.
    [Parameter(Mandatory = $false)][string[]]$TrustedIpRanges = @('203.0.113.0/24', '198.51.100.0/24'),
    # Built-in directory roles whose members are subject to this policy.
    # Includes the most-privileged Azure roles by default.
    [Parameter(Mandatory = $false)][string[]]$TargetRoleNames = @(
        'Global Administrator',
        'Privileged Role Administrator',
        'Security Administrator',
        'User Access Administrator'
    )
)

$ErrorActionPreference = 'Stop'

# Connect to Microsoft Graph with the scopes required to manage CA policies
# and named locations. Both scopes are admin-consent required.
Connect-MgGraph -Scopes 'Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All', 'Directory.Read.All'

# Step 1 — Create a "Trusted IPs" Named Location.
# Named Locations in Entra ID let CA policies reference IP-based or
# country-based location sets. Marking a location as trusted makes it
# eligible for the "exclude trusted locations" condition in CA policies.
Write-Host "Creating Named Location for trusted office IP ranges..."
$ipRangesPayload = $TrustedIpRanges | ForEach-Object {
    @{
        '@odata.type' = '#microsoft.graph.iPv4CidrRange'
        cidrAddress   = $_
    }
}
$namedLocation = New-MgIdentityConditionalAccessNamedLocation -BodyParameter @{
    '@odata.type' = '#microsoft.graph.ipNamedLocation'
    displayName   = 'ent-trusted-office-ips'
    isTrusted     = $true
    ipRanges      = $ipRangesPayload
}
Write-Host "Created Named Location: $($namedLocation.Id)"

# Step 2 — Resolve the role display names to objectIds. CA policies reference
# directory roles by their template ID, which is stable across tenants.
Write-Host "Resolving directory role template IDs..."
$roleTemplateIds = @()
foreach ($roleName in $TargetRoleNames) {
    $template = Get-MgDirectoryRoleTemplate | Where-Object DisplayName -eq $roleName
    if ($template) { $roleTemplateIds += $template.Id }
    else { Write-Warning "Role template not found: $roleName" }
}

# Step 3 — Build the CA policy payload. The policy is created in 'enabledForReportingButNotEnforced'
# mode first so administrators can review impact before flipping to 'enabled'.
Write-Host "Creating Conditional Access policy: $PolicyName"
$policyBody = @{
    displayName     = $PolicyName
    # 'enabledForReportingButNotEnforced' = report-only mode. The policy is
    # evaluated and logged in sign-in logs, but the user is not actually
    # blocked or prompted. Switch to 'enabled' after review.
    state           = 'enabledForReportingButNotEnforced'
    conditions      = @{
        users         = @{
            includeRoles = $roleTemplateIds
        }
        applications  = @{
            # 797f4846-ba00-4fd7-ba43-dac1f8f63013 = Microsoft Azure Management
            # (Azure Portal, ARM REST API, az CLI). Targeting this app id
            # scopes the policy to administrative actions only.
            includeApplications = @('797f4846-ba00-4fd7-ba43-dac1f8f63013')
        }
        locations     = @{
            includeLocations = @('All')
            # excludeLocations referenced by name OR id; using id is the
            # canonical form so the policy survives renames.
            excludeLocations = @($namedLocation.Id)
        }
    }
    grantControls   = @{
        # 'OR' = any one of the specified controls satisfies the policy.
        operator        = 'OR'
        builtInControls = @('mfa')
    }
}

$policy = New-MgIdentityConditionalAccessPolicy -BodyParameter $policyBody
Write-Host "Created CA policy: $($policy.Id)"
Write-Host ""
Write-Host "Policy is in REPORT-ONLY mode. Review sign-in logs for 7 days, then flip to 'enabled' via:"
Write-Host "  Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $($policy.Id) -State enabled"
