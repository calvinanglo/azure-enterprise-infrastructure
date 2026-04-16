// ============================================================================
// Spoke Networks — Web + App tiers with NSGs, UDRs, peering back to hub
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param hubVnetId string
param hubVnetName string
param firewallPrivateIp string
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

var webSpokeName = '${orgPrefix}-vnet-web-${environment}'
var appSpokeName = '${orgPrefix}-vnet-app-${environment}'

var webAddressSpace = '10.1.0.0/16'
var appAddressSpace = '10.2.0.0/16'

var webSubnetPrefix = '10.1.1.0/24'
var appSubnetPrefix = '10.2.1.0/24'

// ── Route Table (force traffic through firewall) ───────────────────────────

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: '${orgPrefix}-rt-spoke-to-fw-${environment}'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'route-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
      {
        name: 'route-spoke-to-spoke'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// ── Web Tier NSG ───────────────────────────────────────────────────────────

resource webNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-nsg-web-${environment}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-LB-Probes'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Bastion-SSH-RDP'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.2.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── App Tier NSG ───────────────────────────────────────────────────────────

resource appNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-nsg-app-${environment}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-From-Web-Tier'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: webSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['8080', '8443']
        }
      }
      {
        name: 'Allow-LB-Probes'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Bastion-SSH-RDP'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.2.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── NSG Diagnostics ────────────────────────────────────────────────────────

resource webNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: webNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

resource appNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: appNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

// ── Web Spoke VNet ─────────────────────────────────────────────────────────

resource webVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: webSpokeName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [webAddressSpace]
    }
    subnets: [
      {
        name: 'snet-web'
        properties: {
          addressPrefix: webSubnetPrefix
          networkSecurityGroup: { id: webNsg.id }
          routeTable: { id: routeTable.id }
        }
      }
    ]
  }
}

// ── App Spoke VNet ─────────────────────────────────────────────────────────

resource appVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: appSpokeName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [appAddressSpace]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: { id: appNsg.id }
          routeTable: { id: routeTable.id }
        }
      }
    ]
  }
}

// ── VNet Peering: Hub ↔ Web Spoke ──────────────────────────────────────────

resource hubToWebPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: '${hubVnetName}/peer-hub-to-web'
  properties: {
    remoteVirtualNetwork: { id: webVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource webToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: webVnet
  name: 'peer-web-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── VNet Peering: Hub ↔ App Spoke ──────────────────────────────────────────

resource hubToAppPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: '${hubVnetName}/peer-hub-to-app'
  properties: {
    remoteVirtualNetwork: { id: appVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource appToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: appVnet
  name: 'peer-app-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output webVnetId string = webVnet.id
output appVnetId string = appVnet.id
output webSubnetId string = '${webVnet.id}/subnets/snet-web'
output appSubnetId string = '${appVnet.id}/subnets/snet-app'
