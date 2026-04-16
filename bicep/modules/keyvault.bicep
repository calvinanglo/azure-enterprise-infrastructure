// ============================================================================
// Key Vault — Secrets, keys, RBAC-based access, diagnostics
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

var keyVaultName = '${orgPrefix}-kv-${environment}-${uniqueString(resourceGroup().id)}'

// ── Key Vault ──────────────────────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: take(keyVaultName, 24)
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true             // RBAC > access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true               // Cannot be disabled once set
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'            // Restrict via firewall rules in prod
    networkAcls: {
      defaultAction: 'Allow'                  // Tighten after initial deployment
      bypass: 'AzureServices'
    }
  }
}

// ── Key Vault Diagnostics ──────────────────────────────────────────────────

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
