// ============================================================================
// Entra ID (Azure AD) — Users, Groups, Administrative Units, App Registration
// Demonstrates: bulk user ops, dynamic groups, AU scoping, guest invite
// AZ-104 Domain: Manage Azure identities and governance (15-20%)
// ============================================================================

// User-Assigned Managed Identities (UAMIs) are the preferred credential-free
// authentication method for workloads running on Azure. Unlike system-assigned
// identities (which are tied to a single resource's lifecycle), UAMIs can be:
//   - Pre-created before the resource they authenticate
//   - Assigned to multiple resources simultaneously
//   - Reused across deployments without rotation
// UAMIs authenticate to Azure AD and obtain tokens to call Azure APIs/services.

// This module deploys at subscription scope to allow RBAC role assignments
// to be made at subscription, resource group, or resource level downstream
targetScope = 'subscription'

// -- Parameters ---------------------------------------------------------------

// Deployment environment (dev / staging / prod) — embedded in identity names
// and tags to distinguish identities across environments in the same tenant
param environment string

// Azure AD tenant domain (e.g. contoso.onmicrosoft.com) used when constructing
// UPN suffixes for scripted user/group operations in the companion PS1 script.
// Defaults to a placeholder — override in parameter files per tenant.
param tenantDomain string = 'contoso.onmicrosoft.com'

// NOTE: Entra ID resources require Microsoft.Graph Bicep extension (preview)
// or az ad CLI commands. Below is the CLI-driven deployment script approach.
// The Bicep below handles the Azure-side RBAC; the companion script
// scripts/entra-setup.ps1 handles the Entra ID objects.

// ── Managed Identity for Automation ────────────────────────────────────────
// Used by VMSS, runbooks, and pipelines — no passwords stored anywhere
// This identity is assigned to automation resources (runbooks, pipelines)
// and granted RBAC roles (e.g. Contributor on specific RGs, Key Vault Secrets
// User) so they can operate without storing service principal credentials.

resource automationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  // Naming convention: id-<purpose>-<environment>; the 'id-' prefix identifies
  // this as a managed identity resource in resource lists and RBAC assignments
  name: 'id-automation-${environment}'
  // Managed identities are region-bound; deploy in the same region as the
  // resources that will use this identity to minimize token acquisition latency
  location: 'eastus2'
  tags: {
    // Environment tag enables cost allocation and policy compliance filtering
    Environment: environment
    // Purpose tag documents why this identity exists — critical for access reviews
    Purpose: 'CI/CD and runbook automation'
  }
}

// ── Managed Identity for Monitoring ────────────────────────────────────────
// Dedicated identity for Log Analytics agents, diagnostic collection services,
// and monitoring pipeline components. Separation from the automation identity
// follows the principle of least privilege: monitoring workloads should never
// have the same permissions as deployment automation.

resource monitoringIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  // Separate identity for monitoring so Log Analytics / diagnostic collection
  // components cannot accidentally (or maliciously) perform automation actions
  name: 'id-monitoring-${environment}'
  location: 'eastus2'
  tags: {
    Environment: environment
    // Purpose tag documents the intended use for access reviews and audits
    Purpose: 'Log Analytics and diagnostic collection'
  }
}

// ── Managed Identity for Backup ────────────────────────────────────────────
// Used by Recovery Services Vault operations (backup jobs, restore operations).
// Granting backup permissions to a dedicated identity means the backup system
// cannot perform compute or network changes even if its token is misused.

resource backupIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  // Separate identity for Recovery Services Vault so backup jobs operate
  // independently of automation and monitoring credential scopes
  name: 'id-backup-${environment}'
  location: 'eastus2'
  tags: {
    Environment: environment
    Purpose: 'Recovery Services Vault operations'
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// These outputs are consumed by parent modules to assign RBAC roles and to
// configure resources (e.g. VMSS identity property, AKS kubelet identity).

// Full ARM resource ID of the automation identity — used to assign the UAMI
// to VMSS instances, App Service, or other compute resources that run automation
output automationIdentityId string = automationIdentity.id

// Azure AD Object (Principal) ID of the automation identity — used to scope
// RBAC role assignments (e.g. Key Vault Secrets User, Storage Blob Data Contributor)
// to this specific managed identity
output automationIdentityPrincipalId string = automationIdentity.properties.principalId

// Principal ID of the monitoring identity — used to assign Monitoring Metrics
// Publisher or Log Analytics Contributor roles for diagnostic data collection
output monitoringIdentityPrincipalId string = monitoringIdentity.properties.principalId

// Principal ID of the backup identity — used to assign Backup Contributor or
// Recovery Services Contributor roles scoped to the RSV resource group
output backupIdentityPrincipalId string = backupIdentity.properties.principalId
