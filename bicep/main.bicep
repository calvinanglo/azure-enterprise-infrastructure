// ============================================================================
// Enterprise Multi-Tier Infrastructure — Orchestrator
// Deploys hub-spoke networking, compute, storage, identity, governance,
// and monitoring in a single subscription scope.
// ============================================================================

targetScope = 'subscription'

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Primary Azure region')
param location string

@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Organization prefix for resource naming')
@minLength(2)
@maxLength(5)
param orgPrefix string = 'ent'

@description('Deployment timestamp for unique naming')
param deploymentTimestamp string = utcNow('yyyyMMddHHmm')

@description('Tags applied to every resource')
param globalTags object = {
  Environment: environment
  ManagedBy: 'Bicep'
  Project: 'enterprise-infra'
  CostCenter: 'IT-OPS'
  DeployedOn: deploymentTimestamp
}

// ── Variables ───────────────────────────────────────────────────────────────

var resourceGroupNames = {
  networking: '${orgPrefix}-rg-networking-${environment}'
  compute: '${orgPrefix}-rg-compute-${environment}'
  storage: '${orgPrefix}-rg-storage-${environment}'
  security: '${orgPrefix}-rg-security-${environment}'
  monitoring: '${orgPrefix}-rg-monitoring-${environment}'
}

// ── Resource Groups ─────────────────────────────────────────────────────────

resource rgNetworking 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.networking
  location: location
  tags: globalTags
}

resource rgCompute 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.compute
  location: location
  tags: globalTags
}

resource rgStorage 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.storage
  location: location
  tags: globalTags
}

resource rgSecurity 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.security
  location: location
  tags: globalTags
}

resource rgMonitoring 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.monitoring
  location: location
  tags: globalTags
}

// ── Module: Monitoring (deployed first — other modules send diagnostics here)

module monitoring 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring-${deploymentTimestamp}'
  scope: rgMonitoring
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
  }
}

// ── Module: Key Vault ───────────────────────────────────────────────────────

module keyvault 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault-${deploymentTimestamp}'
  scope: rgSecurity
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Storage ─────────────────────────────────────────────────────────

module storage 'modules/storage.bicep' = {
  name: 'deploy-storage-${deploymentTimestamp}'
  scope: rgStorage
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Hub Network ─────────────────────────────────────────────────────

module hubNetwork 'modules/hub-network.bicep' = {
  name: 'deploy-hub-network-${deploymentTimestamp}'
  scope: rgNetworking
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Spoke Networks ──────────────────────────────────────────────────

module spokeNetwork 'modules/spoke-network.bicep' = {
  name: 'deploy-spoke-network-${deploymentTimestamp}'
  scope: rgNetworking
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    hubVnetId: hubNetwork.outputs.hubVnetId
    hubVnetName: hubNetwork.outputs.hubVnetName
    firewallPrivateIp: hubNetwork.outputs.firewallPrivateIp
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Load Balancers ──────────────────────────────────────────────────

module loadBalancers 'modules/load-balancers.bicep' = {
  name: 'deploy-load-balancers-${deploymentTimestamp}'
  scope: rgNetworking
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    webSubnetId: spokeNetwork.outputs.webSubnetId
    appSubnetId: spokeNetwork.outputs.appSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Compute (VMSS) ──────────────────────────────────────────────────

module compute 'modules/compute.bicep' = {
  name: 'deploy-compute-${deploymentTimestamp}'
  scope: rgCompute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    webSubnetId: spokeNetwork.outputs.webSubnetId
    appSubnetId: spokeNetwork.outputs.appSubnetId
    webLbBackendPoolId: loadBalancers.outputs.webLbBackendPoolId
    appLbBackendPoolId: loadBalancers.outputs.appLbBackendPoolId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    keyVaultName: keyvault.outputs.keyVaultName
    keyVaultResourceGroup: rgSecurity.name
  }
}

// ── Module: Backup (Recovery Services) ──────────────────────────────────────

module backup 'modules/backup.bicep' = {
  name: 'deploy-backup-${deploymentTimestamp}'
  scope: rgCompute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: DNS ─────────────────────────────────────────────────────────────

module dns 'modules/dns.bicep' = {
  name: 'deploy-dns-${deploymentTimestamp}'
  scope: rgNetworking
  params: {
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    webLbPublicIpId: loadBalancers.outputs.webLbPublicIpId
  }
}

// ── Module: App Service ─────────────────────────────────────────────────────

module appService 'modules/app-service.bicep' = {
  name: 'deploy-appservice-${deploymentTimestamp}'
  scope: rgCompute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    appSubnetId: spokeNetwork.outputs.appSubnetId
  }
}

// ── Module: Containers (ACI + ACR) ──────────────────────────────────────────

module containers 'modules/containers.bicep' = {
  name: 'deploy-containers-${deploymentTimestamp}'
  scope: rgCompute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    appSubnetId: spokeNetwork.outputs.appSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Disks & Snapshots ───────────────────────────────────────────────

module disks 'modules/disks.bicep' = {
  name: 'deploy-disks-${deploymentTimestamp}'
  scope: rgCompute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
  }
}

// ── Module: Governance ──────────────────────────────────────────────────────

module governance 'modules/governance.bicep' = {
  name: 'deploy-governance-${deploymentTimestamp}'
  params: {
    environment: environment
    resourceGroupNames: [
      rgNetworking.name
      rgCompute.name
      rgStorage.name
      rgSecurity.name
      rgMonitoring.name
    ]
  }
}

// ── Module: Identity (RBAC) ─────────────────────────────────────────────────

module identity 'modules/identity.bicep' = {
  name: 'deploy-identity-${deploymentTimestamp}'
  params: {
    environment: environment
    computeResourceGroupId: rgCompute.id
    networkingResourceGroupId: rgNetworking.id
    monitoringResourceGroupId: rgMonitoring.id
  }
}

// ── Module: Entra Identity (Managed Identities) ─────────────────────────────

module entraIdentity 'modules/entra-identity.bicep' = {
  name: 'deploy-entra-identity-${deploymentTimestamp}'
  params: {
    environment: environment
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output resourceGroups object = resourceGroupNames
output hubVnetId string = hubNetwork.outputs.hubVnetId
output bastionPublicIp string = hubNetwork.outputs.bastionPublicIp
output webLbPublicIp string = loadBalancers.outputs.webLbPublicIp
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output keyVaultUri string = keyvault.outputs.keyVaultUri
output storageAccountName string = storage.outputs.storageAccountName
output recoveryVaultName string = backup.outputs.vaultName
output webAppHostname string = appService.outputs.webAppDefaultHostname
output acrLoginServer string = containers.outputs.acrLoginServer
output dnsNameServers array = dns.outputs.publicDnsNameServers
