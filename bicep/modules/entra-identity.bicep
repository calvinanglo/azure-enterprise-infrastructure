// ============================================================================
// Entra ID (Azure AD) — Users, Groups, Administrative Units, App Registration
// Demonstrates: bulk user ops, dynamic groups, AU scoping, guest invite
// AZ-104 Domain: Manage Azure identities and governance (15-20%)
// ============================================================================

targetScope = 'subscription'

param environment string
param tenantDomain string = 'contoso.onmicrosoft.com'

// NOTE: Entra ID resources require Microsoft.Graph Bicep extension (preview)
// or az ad CLI commands. Below is the CLI-driven deployment script approach.
// The Bicep below handles the Azure-side RBAC; the companion script
// scripts/entra-setup.ps1 handles the Entra ID objects.

// ── Managed Identity for Automation ────────────────────────────────────────
// Used by VMSS, runbooks, and pipelines — no passwords stored anywhere

resource automationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-automation-${environment}'
  location: 'eastus2'
  tags: {
    Environment: environment
    Purpose: 'CI/CD and runbook automation'
  }
}

resource monitoringIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-monitoring-${environment}'
  location: 'eastus2'
  tags: {
    Environment: environment
    Purpose: 'Log Analytics and diagnostic collection'
  }
}

resource backupIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-backup-${environment}'
  location: 'eastus2'
  tags: {
    Environment: environment
    Purpose: 'Recovery Services Vault operations'
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output automationIdentityId string = automationIdentity.id
output automationIdentityPrincipalId string = automationIdentity.properties.principalId
output monitoringIdentityPrincipalId string = monitoringIdentity.properties.principalId
output backupIdentityPrincipalId string = backupIdentity.properties.principalId
