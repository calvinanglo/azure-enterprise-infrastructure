# ============================================================================
# define-custom-security-attributes.ps1
# Creates an Entra ID Custom Security Attribute set and 3 attribute values.
# Custom security attributes are key-value pairs assigned to Entra ID users,
# groups, applications, and managed identities. Unlike directory extensions,
# they support fine-grained ABAC (Attribute-Based Access Control) for Azure
# RBAC role assignment conditions.
#
# AZ-104 Domain: Manage Azure identities and governance
#
# Permissions: Caller must hold the 'Attribute Definition Administrator' or
# 'Attribute Assignment Administrator' role in Entra ID. Global Admin alone
# is NOT sufficient — these attribute roles must be explicitly granted.
# ============================================================================

param(
    # Attribute set name — appears in the portal under Entra ID → Custom
    # security attributes. Must be unique in the tenant.
    [Parameter(Mandatory = $false)][string]$AttributeSetName = 'WorkforcePartition',
    [Parameter(Mandatory = $false)][string]$AttributeSetDescription = 'Logical workforce partition tag for ABAC role conditions'
)

$ErrorActionPreference = 'Stop'

Connect-MgGraph -Scopes 'CustomSecAttributeDefinition.ReadWrite.All'

# Step 1 — Create the attribute set. An "attribute set" is a container that
# groups related attribute definitions together. Naming the set after the
# governance domain (e.g. WorkforcePartition) makes RBAC conditions readable.
Write-Host "Creating attribute set: $AttributeSetName"
$set = New-MgDirectoryAttributeSet -BodyParameter @{
    id            = $AttributeSetName
    description   = $AttributeSetDescription
    # maxAttributesPerSet bounds future growth — 25 is the system limit.
    maxAttributesPerSet = 25
}
Write-Host "Attribute set created."

# Step 2 — Define an attribute called 'Tier' with predefined allowed values.
# Predefined values prevent typos and enable dropdown selection in the portal.
# Without predefined values, operators can assign arbitrary free-text values.
Write-Host "Defining attribute 'Tier' with 3 predefined values..."
$attr = New-MgDirectoryCustomSecurityAttributeDefinition -BodyParameter @{
    attributeSet              = $AttributeSetName
    name                      = 'Tier'
    description               = 'Workforce tier classification used in RBAC conditions'
    type                      = 'String'
    status                    = 'Available'
    isCollection              = $false  # single value per assignment, not array
    isSearchable              = $true   # exposed in user search filters
    usePreDefinedValuesOnly   = $true   # forces dropdown of predefined values
}

# Predefined values — assigned via separate calls because the New-... cmdlet
# above doesn't support inline allowedValues on creation in the v2 module.
$values = @(
    @{ id = 'Tier1Engineering'; isActive = $true },
    @{ id = 'GovOps'; isActive = $true },
    @{ id = 'PartnerLite'; isActive = $true }
)
foreach ($v in $values) {
    Write-Host "  Adding predefined value: $($v.id)"
    New-MgDirectoryCustomSecurityAttributeDefinitionAllowedValue `
        -CustomSecurityAttributeDefinitionId "${AttributeSetName}_Tier" `
        -BodyParameter $v
}

Write-Host ""
Write-Host "Custom security attribute '${AttributeSetName}.Tier' is ready."
Write-Host "Assign to users via Portal → Entra ID → Users → <user> → Custom security attributes."
Write-Host "Reference in RBAC conditions like: @Principal[Microsoft.Directory/CustomSecurityAttributes/${AttributeSetName}/Tier] StringEqualsIgnoreCase 'Tier1Engineering'"
