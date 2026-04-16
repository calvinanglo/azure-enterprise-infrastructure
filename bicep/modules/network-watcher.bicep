// ============================================================================
// Network Watcher — NSG flow logs, connection monitor, IP flow verify setup
// AZ-104 Domain: Configure and manage virtual networking
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string
param webNsgId string
param appNsgId string
param storageAccountId string

// ── Network Watcher (auto-created per region, but we ensure it exists) ────

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' = {
  name: 'NetworkWatcher_${location}'
  location: location
  tags: tags
}

// ── NSG Flow Logs: Web Tier ───────────────────────────────────────────────

resource webFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  parent: networkWatcher
  name: '${orgPrefix}-flowlog-web-${environment}'
  location: location
  tags: tags
  properties: {
    targetResourceId: webNsgId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      enabled: true
      days: environment == 'prod' ? 90 : 30
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: logAnalyticsWorkspaceId
        trafficAnalyticsInterval: 10
      }
    }
  }
}

// ── NSG Flow Logs: App Tier ───────────────────────────────────────────────

resource appFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  parent: networkWatcher
  name: '${orgPrefix}-flowlog-app-${environment}'
  location: location
  tags: tags
  properties: {
    targetResourceId: appNsgId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      enabled: true
      days: environment == 'prod' ? 90 : 30
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: logAnalyticsWorkspaceId
        trafficAnalyticsInterval: 10
      }
    }
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output networkWatcherName string = networkWatcher.name
output webFlowLogId string = webFlowLog.id
output appFlowLogId string = appFlowLog.id
