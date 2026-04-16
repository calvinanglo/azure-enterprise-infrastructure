// ============================================================================
// Disk Management — Managed disks, snapshots, disk encryption, shared image
// AZ-104 Domain: Deploy and manage Azure compute resources
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object

// ── Managed Data Disk (attachable to VMs) ─────────────────────────────────

resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: '${orgPrefix}-disk-data-shared-${environment}'
  location: location
  tags: tags
  sku: {
    name: environment == 'prod' ? 'Premium_LRS' : 'StandardSSD_LRS'
  }
  properties: {
    diskSizeGB: 128
    creationData: {
      createOption: 'Empty'
    }
    encryption: {
      type: 'EncryptionAtRestWithPlatformKey'
    }
    tier: environment == 'prod' ? 'P10' : null
    networkAccessPolicy: 'DenyAll'             // No public access to disk
    publicNetworkAccess: 'Disabled'
  }
}

// ── Snapshot of Data Disk ─────────────────────────────────────────────────

resource diskSnapshot 'Microsoft.Compute/snapshots@2023-10-02' = {
  name: '${orgPrefix}-snap-data-${environment}-baseline'
  location: location
  tags: union(tags, { SnapshotType: 'baseline' })
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Copy'
      sourceResourceId: dataDisk.id
    }
    incremental: true                          // Incremental = cheaper
  }
}

// ── Azure Compute Gallery (Shared Image Gallery) ──────────────────────────

resource computeGallery 'Microsoft.Compute/galleries@2022-08-03' = {
  name: '${orgPrefix}_gallery_${environment}'
  location: location
  tags: tags
  properties: {
    description: 'Golden images for ${environment} VMSS deployments'
  }
}

// ── Image Definition ──────────────────────────────────────────────────────

resource imageDefinition 'Microsoft.Compute/galleries/images@2022-08-03' = {
  parent: computeGallery
  name: 'ubuntu-web-golden'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    identifier: {
      publisher: orgPrefix
      offer: 'WebServer'
      sku: 'Ubuntu2204-Nginx'
    }
    recommended: {
      vCPUs: { min: 2, max: 8 }
      memory: { min: 4, max: 32 }
    }
    features: [
      { name: 'SecurityType', value: 'TrustedLaunch' }
    ]
  }
}

// ── Disk Encryption Set (customer-managed keys via Key Vault) ─────────────
// NOTE: Requires Key Vault key — wired in main.bicep after KV deployment

// resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
//   name: '${orgPrefix}-des-${environment}'
//   location: location
//   tags: tags
//   identity: { type: 'SystemAssigned' }
//   properties: {
//     activeKey: {
//       keyUrl: '<KEY_VAULT_KEY_URL>'
//     }
//     encryptionType: 'EncryptionAtRestWithCustomerKey'
//   }
// }

// ── Outputs ────────────────────────────────────────────────────────────────

output dataDiskId string = dataDisk.id
output snapshotId string = diskSnapshot.id
output galleryName string = computeGallery.name
output imageDefinitionId string = imageDefinition.id
