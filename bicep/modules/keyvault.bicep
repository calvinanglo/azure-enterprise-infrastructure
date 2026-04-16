// ============================================================================
// Key Vault — Secrets, keys, RBAC-based access, diagnostics
// AZ-104 Domain: Implement and manage storage / Manage Azure identities
// Key Vault centralizes secrets management so no credentials live in code or
// config files. RBAC-based access replaces legacy access policies (simpler,
// auditable via Azure AD sign-in logs).
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region where all resources in this module are deployed
param location string

// Deployment environment (dev / staging / prod) — drives retention and enforcement
param environment string

// Short organization prefix used in all resource names for easy identification
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// Resource ID of the Log Analytics Workspace that receives all diagnostic data
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

// Key Vault names must be globally unique, 3–24 chars, alphanumeric + hyphens.
// uniqueString() produces a deterministic 13-char hash of the resource group ID,
// ensuring re-deployments get the same name without naming collisions across tenants.
var keyVaultName = '${orgPrefix}-kv-${environment}-${uniqueString(resourceGroup().id)}'

// ── Key Vault ──────────────────────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  // take() truncates to the 24-char Key Vault name limit
  name: take(keyVaultName, 24)
  location: location
  tags: tags
  properties: {
    // tenantId links the vault to the correct Azure AD tenant for identity resolution
    tenantId: subscription().tenantId
    sku: {
      // 'A' is the only supported family for standard/premium tiers
      family: 'A'
      // 'standard' supports software-protected keys; use 'premium' for HSM-backed keys
      name: 'standard'
    }
    // RBAC authorization replaces vault access policies; roles are assigned at vault
    // or secret/key/certificate scope via Azure RBAC (e.g. Key Vault Secrets Officer)
    enableRbacAuthorization: true             // RBAC > access policies
    // Soft-delete prevents immediate permanent deletion — objects recoverable for
    // softDeleteRetentionInDays after deletion; required for compliance environments
    enableSoftDelete: true
    // 90-day retention window before a soft-deleted vault/object is permanently gone;
    // maximum allowed value and recommended for production
    softDeleteRetentionInDays: 90
    // Purge protection prevents even subscription owners from permanently deleting
    // soft-deleted vault objects before the retention period expires; cannot be disabled
    enablePurgeProtection: true               // Cannot be disabled once set
    // Allows Azure VMs (in the same subscription) to retrieve certificates stored
    // here for use in VM deployments (e.g. WinRM, IIS SSL certs)
    enabledForDeployment: true
    // Allows ARM template deployments to retrieve secrets during resource provisioning
    enabledForTemplateDeployment: true
    // Disk encryption via Azure Disk Encryption (ADE) does NOT use Key Vault key
    // wrapping in this deployment; set true only if using ADE with customer-managed keys
    enabledForDiskEncryption: false
    // Public network access is enabled here for initial deployment convenience.
    // In production, restrict using firewall rules (IP allowlists) or Private Endpoints
    publicNetworkAccess: 'Enabled'            // Restrict via firewall rules in prod
    networkAcls: {
      // 'Allow' permits all traffic not matched by firewall rules; tighten to 'Deny'
      // and add explicit IP rules / VNet service endpoints after initial deployment
      defaultAction: 'Allow'                  // Tighten after initial deployment
      // 'AzureServices' allows trusted Microsoft first-party services (ARM, Azure
      // Backup, Azure Monitor, etc.) to bypass the network ACL even when defaultAction
      // is set to 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// ── Key Vault Diagnostics ──────────────────────────────────────────────────
// Diagnostic settings stream audit and operational logs to Log Analytics.
// Key Vault audit logs (who accessed/modified which secret, when, from where)
// are critical for security investigations and compliance reporting (AZ-104 exam
// topic: monitoring and diagnostics).

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  // Friendly name for the diagnostic setting; appears in the portal diagnostics blade
  name: 'send-to-law'
  // scope pins this diagnostic setting to the Key Vault resource above
  scope: keyVault
  properties: {
    // Destination workspace; all logs and metrics flow to this Log Analytics Workspace
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        // 'allLogs' category group captures every log category the resource emits,
        // including AuditEvent, AzurePolicyEvaluationDetails, etc.
        categoryGroup: 'allLogs'
        enabled: true
      }
      {
        // 'audit' category group captures only the security-relevant audit events
        // (access to secrets/keys/certs, vault management changes)
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      // AllMetrics sends vault availability and latency data to Log Analytics
      // for alerting and dashboard use
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Outputs are consumed by parent modules or main.bicep to wire up downstream
// resources (e.g. setting Key Vault references in App Service, granting RBAC).

// Short name used in RBAC assignments and app configuration references
output keyVaultName string = keyVault.name

// Full ARM resource ID used to scope RBAC role assignments to this vault
output keyVaultId string = keyVault.id

// HTTPS URI (e.g. https://<name>.vault.azure.net/) used by applications and
// managed identities to construct secret/key reference URIs
output keyVaultUri string = keyVault.properties.vaultUri
