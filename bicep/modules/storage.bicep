// ============================================================================
// Storage — Blob + Files with lifecycle management, private endpoint ready
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

// Storage account names: 3-24 chars, lowercase alphanumeric only
var storageAccountName = '${orgPrefix}st${environment}${uniqueString(resourceGroup().id)}'
var redundancy = environment == 'prod' ? 'GRS' : 'LRS'

// ── Storage Account ────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: take(storageAccountName, 24)
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_${redundancy}'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true               // Disable after RBAC migration
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
      }
    }
  }
}

// ── Blob Service ───────────────────────────────────────────────────────────

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: environment == 'prod' ? 30 : 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    changeFeed: {
      enabled: true
    }
    isVersioningEnabled: true
  }
}

// ── Blob Containers ────────────────────────────────────────────────────────

resource appDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'app-data'
  properties: {
    publicAccess: 'None'
  }
}

resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'backups'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'vm-backups-and-snapshots'
    }
  }
}

resource logsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'diagnostic-logs'
  properties: {
    publicAccess: 'None'
  }
}

// ── File Share ─────────────────────────────────────────────────────────────

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

resource configShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'config-share'
  properties: {
    shareQuota: 50
    accessTier: 'TransactionOptimized'
  }
}

// ── Lifecycle Management ───────────────────────────────────────────────────

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'move-to-cool-after-30d'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['backups/', 'diagnostic-logs/']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }
              snapshot: {
                delete: {
                  daysAfterCreationGreaterThan: 90
                }
              }
            }
          }
        }
        {
          name: 'delete-old-versions'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
            }
            actions: {
              version: {
                delete: {
                  daysAfterCreationGreaterThan: 60
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ── Storage Diagnostics ────────────────────────────────────────────────────

resource storageDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'StorageRead', enabled: true }
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output fileEndpoint string = storageAccount.properties.primaryEndpoints.file
