// ============================================================================
// Containers — Azure Container Instances + Azure Container Registry
// AZ-104 Domain: Deploy and manage Azure compute resources
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param appSubnetId string
param logAnalyticsWorkspaceId string

// ── Azure Container Registry ──────────────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${orgPrefix}acr${environment}${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: {
    name: environment == 'prod' ? 'Standard' : 'Basic'
  }
  properties: {
    adminUserEnabled: false                    // Use managed identity, not admin
    publicNetworkAccess: 'Enabled'
    policies: {
      retentionPolicy: {
        status: 'enabled'
        days: 30
      }
    }
  }
}

// ── Container Instance: Monitoring Sidecar ────────────────────────────────

resource monitoringContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${orgPrefix}-aci-monitor-${environment}'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    sku: 'Standard'
    containers: [
      {
        name: 'health-checker'
        properties: {
          image: 'curlimages/curl:latest'
          command: [
            '/bin/sh'
            '-c'
            'while true; do curl -sf http://10.1.1.4/health || echo "UNHEALTHY $(date)"; sleep 30; done'
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
          environmentVariables: [
            { name: 'ENVIRONMENT', value: environment }
          ]
        }
      }
    ]
    diagnostics: {
      logAnalytics: {
        workspaceId: reference(logAnalyticsWorkspaceId, '2022-10-01').customerId
        workspaceKey: listKeys(logAnalyticsWorkspaceId, '2022-10-01').primarySharedKey
      }
    }
    ipAddress: {
      type: 'Private'
      ports: [
        { port: 80, protocol: 'TCP' }
      ]
    }
    subnetIds: [
      { id: appSubnetId }
    ]
  }
}

// ── Container Instance: Utility/Job Runner ────────────────────────────────

resource utilityContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${orgPrefix}-aci-utility-${environment}'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    containers: [
      {
        name: 'azcopy-backup'
        properties: {
          image: 'mcr.microsoft.com/azure-cli:latest'
          command: [
            '/bin/sh'
            '-c'
            'echo "Utility container ready for ad-hoc tasks"'
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
        }
      }
    ]
    ipAddress: {
      type: 'Public'
      ports: [
        { port: 80, protocol: 'TCP' }
      ]
    }
  }
}

// ── ACR Diagnostics ───────────────────────────────────────────────────────

resource acrDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: acr
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output monitoringContainerId string = monitoringContainer.id
