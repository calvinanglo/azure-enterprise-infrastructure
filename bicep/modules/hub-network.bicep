// ============================================================================
// Hub Network — Central connectivity: Firewall, Bastion, DNS, VPN Gateway
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

var hubVnetName = '${orgPrefix}-vnet-hub-${environment}'
var hubAddressSpace = '10.0.0.0/16'

var subnets = {
  firewall: {
    name: 'AzureFirewallSubnet'            // Required name
    addressPrefix: '10.0.1.0/26'
  }
  bastion: {
    name: 'AzureBastionSubnet'             // Required name
    addressPrefix: '10.0.2.0/26'
  }
  gateway: {
    name: 'GatewaySubnet'                  // Required name
    addressPrefix: '10.0.3.0/27'
  }
  management: {
    name: 'snet-management'
    addressPrefix: '10.0.4.0/24'
  }
}

// ── Hub Virtual Network ────────────────────────────────────────────────────

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: hubVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [hubAddressSpace]
    }
    subnets: [
      {
        name: subnets.firewall.name
        properties: {
          addressPrefix: subnets.firewall.addressPrefix
        }
      }
      {
        name: subnets.bastion.name
        properties: {
          addressPrefix: subnets.bastion.addressPrefix
        }
      }
      {
        name: subnets.gateway.name
        properties: {
          addressPrefix: subnets.gateway.addressPrefix
        }
      }
      {
        name: subnets.management.name
        properties: {
          addressPrefix: subnets.management.addressPrefix
          networkSecurityGroup: {
            id: managementNsg.id
          }
        }
      }
    ]
  }
}

// ── Management Subnet NSG ──────────────────────────────────────────────────

resource managementNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-nsg-management-${environment}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: subnets.bastion.addressPrefix
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

// ── NSG Diagnostic Settings ────────────────────────────────────────────────

resource managementNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: managementNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// ── Azure Firewall ─────────────────────────────────────────────────────────

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${orgPrefix}-pip-fw-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: '${orgPrefix}-fwpolicy-${environment}'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: environment == 'prod' ? 'Standard' : 'Basic'
    }
    threatIntelMode: 'Deny'
  }
}

resource firewallPolicyRuleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternet'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['53']
            ipProtocols: ['TCP', 'UDP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['123']
            ipProtocols: ['UDP']
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: '${orgPrefix}-fw-${environment}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: environment == 'prod' ? 'Standard' : 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          publicIPAddress: {
            id: firewallPip.id
          }
          subnet: {
            id: '${hubVnet.id}/subnets/${subnets.firewall.name}'
          }
        }
      }
    ]
  }
}

// ── Firewall Diagnostics ───────────────────────────────────────────────────

resource firewallDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ── Azure Bastion ──────────────────────────────────────────────────────────

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${orgPrefix}-pip-bastion-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: '${orgPrefix}-bastion-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: '${hubVnet.id}/subnets/${subnets.bastion.name}'
          }
        }
      }
    ]
  }
}

// ── Private DNS Zone (for private endpoints) ───────────────────────────────

resource privateDnsBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource privateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsBlob
  name: 'link-hub'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: hubVnet.id
    }
    registrationEnabled: false
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output hubVnetId string = hubVnet.id
output hubVnetName string = hubVnet.name
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output bastionPublicIp string = bastionPip.properties.ipAddress
output privateDnsZoneId string = privateDnsBlob.id
