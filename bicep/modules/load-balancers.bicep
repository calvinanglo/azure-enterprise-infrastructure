// ============================================================================
// Load Balancers — Public (web tier) + Internal (app tier)
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param webSubnetId string
param appSubnetId string
param logAnalyticsWorkspaceId string

// ── Public Load Balancer (Web Tier) ────────────────────────────────────────

resource webLbPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${orgPrefix}-pip-lb-web-${environment}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource webLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: '${orgPrefix}-lb-web-${environment}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'web-frontend'
        properties: {
          publicIPAddress: { id: webLbPip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: 'web-backend-pool' }
    ]
    probes: [
      {
        name: 'http-probe'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/health'
          intervalInSeconds: 15
          numberOfProbes: 2
          probeThreshold: 1
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-web-${environment}', 'http-probe')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          disableOutboundSnat: true
        }
      }
      {
        name: 'https-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-web-${environment}', 'http-probe')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          disableOutboundSnat: true
        }
      }
    ]
    outboundRules: [
      {
        name: 'web-outbound'
        properties: {
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }
          protocol: 'All'
          enableTcpReset: true
          idleTimeoutInMinutes: 4
          allocatedOutboundPorts: 1024
        }
      }
    ]
  }
}

// ── Internal Load Balancer (App Tier) ──────────────────────────────────────

resource appLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: '${orgPrefix}-lb-app-${environment}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'app-frontend'
        properties: {
          subnet: { id: appSubnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    backendAddressPools: [
      { name: 'app-backend-pool' }
    ]
    probes: [
      {
        name: 'app-health-probe'
        properties: {
          protocol: 'Tcp'
          port: 8080
          intervalInSeconds: 15
          numberOfProbes: 2
          probeThreshold: 1
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'app-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-app-${environment}', 'app-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-app-${environment}', 'app-backend-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-app-${environment}', 'app-health-probe')
          }
          protocol: 'Tcp'
          frontendPort: 8080
          backendPort: 8080
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// ── LB Diagnostics ────────────────────────────────────────────────────────

resource webLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: webLb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource appLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: appLb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output webLbPublicIp string = webLbPip.properties.ipAddress
output webLbPublicIpId string = webLbPip.id
output webLbBackendPoolId string = webLb.properties.backendAddressPools[0].id
output appLbBackendPoolId string = appLb.properties.backendAddressPools[0].id
