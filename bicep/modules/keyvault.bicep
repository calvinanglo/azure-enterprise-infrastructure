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

// Toggle for public network access. When private endpoints are deployed, set
// this to 'Disabled' so the vault is only reachable from in-VNet workloads.
// Default 'Disabled' enforces the secure-by-default posture; set to 'Enabled'
// only for dev/test scenarios that lack PE infrastructure.
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

// Allow ADE (Azure Disk Encryption) to retrieve the key encryption key (KEK)
// from this vault for unwrapping data encryption keys at VM boot.
// Set to true when this vault stores the KEK used by enable-disk-encryption.ps1.
param enableForDiskEncryption bool = true

// existingKeyVaultName: optional override for the vault name. Same pattern as
// the storage module — supply this when the vault was created outside Bicep
// so the deployment updates it in place instead of creating a duplicate.
param existingKeyVaultName string = ''

// ── Variables ───────────────────────────────────────────────────────────────

// Key Vault names must be globally unique, 3–24 chars, alphanumeric + hyphens.
// uniqueString() produces a deterministic 13-char hash of the resource group ID,
// ensuring re-deployments get the same name without naming collisions across tenants.
// Pin to the existing vault name when supplied; otherwise generate a fresh
// globally-unique name from orgPrefix + uniqueString hash.
var keyVaultName = empty(existingKeyVaultName) ? '${orgPrefix}-kv-${environment}-${uniqueString(resourceGroup().id)}' : existingKeyVaultName

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
    // Allow Azure Disk Encryption to retrieve the KEK (key encryption key)
    // stored in this vault. ADE wraps the per-VM data encryption key with the
    // KEK so VM disks can be unsealed at boot using the vault's authority.
    // Required when this vault is the KEK source for enable-disk-encryption.ps1.
    enabledForDiskEncryption: enableForDiskEncryption
    // Default: 'Disabled'. With private endpoints deployed, the vault is only
    // reachable from in-VNet workloads via the PE. Public DNS still resolves
    // to a public IP but firewall rules drop the traffic. This is the
    // secure-by-default posture per Azure Security Benchmark.
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      // 'Deny' enforces the lockdown — only traffic from VNets explicitly
      // listed in virtualNetworkRules (or the AzureServices bypass) can reach
      // the vault. Combined with publicNetworkAccess: 'Disabled', this is
      // belt-and-suspenders security.
      defaultAction: 'Deny'
      // 'AzureServices' allows trusted Microsoft first-party services (Azure
      // Backup, ARM template deployments, Defender for Cloud, etc.) to bypass
      // the deny rule. Without this, ARM-driven secret retrieval during
      // deployments would fail.
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
