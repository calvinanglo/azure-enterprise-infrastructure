// ============================================================================
// Private Endpoints — Storage Account + Key Vault, with Private DNS zones
// AZ-104 Domain: Networking + Storage + Security
// ============================================================================
// AZ-104 Context: A Private Endpoint (PE) is a NIC inside your VNet that maps
// to a specific PaaS resource (storage account, key vault, SQL DB, etc.). PE
// traffic flows over Microsoft's private backbone — no public internet hop —
// and is protected by NSG/UDR routing on the source side. PE makes it possible
// to set the PaaS resource's publicNetworkAccess = Disabled while still
// allowing in-VNet workloads to reach it.
//
// Two parts deployed here:
//   1. Private Endpoint resource → creates a NIC in the target subnet
//   2. Private DNS Zone Group → wires the PE NIC's IP into a private DNS zone
//      (e.g. privatelink.blob.core.windows.net) so apps resolve the storage
//      account name to the private IP automatically. Without the DNS zone
//      group, apps would still get the public IP from public DNS.
//
// Cost: each PE costs ~$7.30/mo + $0.01/GB processed (negligible for low traffic).

// -- Parameters --------------------------------------------------------------

// Azure region. PEs and their associated Private DNS zones must be in the
// same region as the target PaaS resource (or the closest paired region).
param location string

// Deployment environment for PE name suffixes (dev / staging / prod).
param environment string

// Org prefix for CAF naming consistency with other resources.
param orgPrefix string

// Tag object inherited from main.bicep.
param tags object

// Subnet ID where PE NICs are allocated (snet-pe in the app spoke).
// This subnet must have privateEndpointNetworkPolicies = Disabled.
param peSubnetId string

// Resource ID of the Storage Account that gets the private endpoint.
// PE binds to a specific subresource (blob, file, queue, table, etc.) —
// here we expose the blob endpoint only.
param storageAccountId string

// Resource ID of the Key Vault that gets the private endpoint.
// Key Vault PE always uses the 'vault' subresource group.
param keyVaultId string

// VNet IDs for the Private DNS Zone virtual network links. Each private DNS
// zone must be linked to every VNet that needs to resolve PE FQDNs to private
// IPs. Linking to all 3 VNets ensures hub-management and both spokes resolve
// correctly.
param hubVnetId string
param webVnetId string
param appVnetId string

// ── Private DNS Zone: Storage Blob ──────────────────────────────────────────
// AZ-104 Context: privatelink.blob.core.windows.net is the well-known zone
// name for Azure Blob Storage private endpoints. The Azure-managed PE DNS
// integration registers an A record like
//   <storageAccountName>.privatelink.blob.core.windows.net → 10.2.2.4
// so that DNS lookups for <storageAccountName>.blob.core.windows.net follow
// the CNAME chain through privatelink.* and resolve to the private IP.
//
// Private DNS zones are GLOBAL resources (location: 'global'). They are free
// to deploy and only billed for query volume above the free tier.

resource pdnsBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  // Zone name must match the public service exactly — Azure rejects deviations.
  name: 'privatelink.blob.core.windows.net'
  // PDZ resources are global; 'global' is the only valid location.
  location: 'global'
  tags: tags
}

// VNet links — one per VNet that should resolve the private FQDN.
// Without a link, lookups in that VNet fall through to public DNS and
// resolve to the public IP, defeating the private endpoint isolation.

resource pdnsBlobLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsBlob
  // Naming pattern <zone>-<vnet> makes the relationship visible in the portal.
  name: 'link-hub'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: hubVnetId }
    // Disable auto-registration: only manual A records (PE-managed) are needed.
    // Auto-registration would create an A record for every VM NIC in the VNet,
    // which we explicitly do not want for the private DNS zone.
    registrationEnabled: false
  }
}

resource pdnsBlobLinkWeb 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsBlob
  name: 'link-web'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: webVnetId }
    registrationEnabled: false
  }
}

resource pdnsBlobLinkApp 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsBlob
  name: 'link-app'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: appVnetId }
    registrationEnabled: false
  }
}

// ── Private Endpoint: Storage Blob ──────────────────────────────────────────
// AZ-104 Context: A Private Endpoint allocates a NIC from peSubnetId and
// binds it to the storage account's blob subresource. Once deployed, the
// storage account can have publicNetworkAccess set to Disabled and only
// in-VNet traffic (or whitelisted on-prem via VPN/ExpressRoute) can reach
// blobs. This is a required pattern for security-sensitive workloads
// (PCI, HIPAA, FedRAMP).

resource peStorage 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  // Naming pattern: <orgPrefix>-pe-<service>-<environment>
  name: '${orgPrefix}-pe-storage-${environment}'
  location: location
  tags: tags
  properties: {
    // Subnet hosts the PE NIC; must have PE network policies disabled.
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        // Friendly name for the connection — visible on the storage account's
        // "Networking" → "Private endpoint connections" blade.
        name: 'plsc-storage-blob'
        properties: {
          // Target PaaS resource for the PE.
          privateLinkServiceId: storageAccountId
          // groupIds is the subresource selector. For storage:
          //   blob, blob_secondary, file, file_secondary, queue, table, web, dfs
          // We expose only the blob endpoint here; additional PEs would be
          // needed for file, queue, etc. (each is billed separately).
          groupIds: ['blob']
        }
      }
    ]
  }
  // Explicit dependency on the DNS zone vnet links — the PE deployment can
  // succeed before the DNS zone group registration finishes if the link
  // doesn't yet exist, leaving FQDN resolution broken.
  dependsOn: [
    pdnsBlobLinkHub
    pdnsBlobLinkWeb
    pdnsBlobLinkApp
  ]
}

// Private DNS Zone Group — registers the PE NIC's IP into the private zone
// so DNS resolution of the storage FQDN returns the private IP automatically.
// Without this resource, the PE NIC has an IP but no DNS record, and apps
// would need /etc/hosts entries or custom DNS to use it.

resource peStorageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peStorage
  // Standard name; not exposed in the portal UI.
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        // Friendly identifier for this zone configuration.
        name: 'config-blob'
        properties: {
          // Points to the private DNS zone above; Azure auto-creates an
          // A record for the storage account inside this zone.
          privateDnsZoneId: pdnsBlob.id
        }
      }
    ]
  }
}

// ── Private DNS Zone: Key Vault ─────────────────────────────────────────────
// AZ-104 Context: Same pattern as blob, but for Key Vault. The well-known
// zone name is privatelink.vaultcore.azure.net. Apps resolving
// <vault>.vault.azure.net follow the CNAME to privatelink.vaultcore.azure.net
// and get the PE's private IP.

resource pdnsKv 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource pdnsKvLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsKv
  name: 'link-hub'
  location: 'global'
  properties: {
    virtualNetwork: { id: hubVnetId }
    registrationEnabled: false
  }
}

resource pdnsKvLinkWeb 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsKv
  name: 'link-web'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: webVnetId }
    registrationEnabled: false
  }
}

resource pdnsKvLinkApp 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pdnsKv
  name: 'link-app'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: appVnetId }
    registrationEnabled: false
  }
}

// ── Private Endpoint: Key Vault ─────────────────────────────────────────────
// AZ-104 Context: Once this PE is deployed, Key Vault publicNetworkAccess can
// be set to 'Disabled' so secrets are reachable only over the private network.
// This is a critical pattern for storing high-value secrets (database
// credentials, signing keys) without exposing them via a public endpoint.

resource peKv 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${orgPrefix}-pe-kv-${environment}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'plsc-keyvault'
        properties: {
          privateLinkServiceId: keyVaultId
          // 'vault' is the only subresource for Key Vault private endpoints.
          groupIds: ['vault']
        }
      }
    ]
  }
  dependsOn: [
    pdnsKvLinkHub
    pdnsKvLinkWeb
    pdnsKvLinkApp
  ]
}

resource peKvDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peKv
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config-vault'
        properties: {
          privateDnsZoneId: pdnsKv.id
        }
      }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Exposed for downstream modules / verification scripts that need to reference
// the PEs by ID (e.g. diagnostic settings, reporting).

output peStorageId string = peStorage.id
output peKeyVaultId string = peKv.id
output pdnsBlobZoneName string = pdnsBlob.name
output pdnsKvZoneName string = pdnsKv.name
