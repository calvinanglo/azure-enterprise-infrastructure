// ============================================================================
// App Service — Web App, App Service Plan, deployment slots, scaling, TLS
// AZ-104 Domain: Deploy and manage Azure compute resources
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string
param appSubnetId string

// ── App Service Plan ──────────────────────────────────────────────────────

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${orgPrefix}-asp-${environment}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: environment == 'prod' ? 'S1' : 'B1'
    tier: environment == 'prod' ? 'Standard' : 'Basic'
    capacity: environment == 'prod' ? 2 : 1
  }
  properties: {
    reserved: true                             // Required for Linux
    zoneRedundant: environment == 'prod'
  }
}

// ── Web App ───────────────────────────────────────────────────────────────

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${orgPrefix}-webapp-${environment}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: appSubnetId
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: environment == 'prod'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/health'
      appSettings: [
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
        {
          name: 'ENVIRONMENT'
          value: environment
        }
      ]
    }
  }
}

// ── Deployment Slot: Staging ──────────────────────────────────────────────

resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = if (environment == 'prod') {
  parent: webApp
  name: 'staging'
  location: location
  tags: union(tags, { Slot: 'staging' })
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      autoSwapSlotName: 'production'          // Auto-swap after warm-up
      appSettings: [
        {
          name: 'ENVIRONMENT'
          value: 'staging'
        }
      ]
    }
  }
}

// ── Autoscale: App Service ────────────────────────────────────────────────

resource appServiceAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if (environment == 'prod') {
  name: '${orgPrefix}-autoscale-asp-${environment}'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: appServicePlan.id
    profiles: [
      {
        name: 'DefaultProfile'
        capacity: {
          minimum: '2'
          maximum: '5'
          default: '2'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: appServicePlan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: appServicePlan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 25
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

// ── Web App Diagnostics ───────────────────────────────────────────────────

resource webAppDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: webApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceAppLogs', enabled: true }
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output webAppName string = webApp.name
output webAppDefaultHostname string = webApp.properties.defaultHostName
output webAppPrincipalId string = webApp.identity.principalId
output appServicePlanId string = appServicePlan.id
