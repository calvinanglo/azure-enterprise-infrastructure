// ============================================================================
// Compute — VM Scale Sets for web + app tiers with extensions
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param webSubnetId string
param appSubnetId string
param webLbBackendPoolId string
param appLbBackendPoolId string
param logAnalyticsWorkspaceId string
param keyVaultName string
param keyVaultResourceGroup string

@secure()
@description('Admin username — injected at deploy time, never hardcoded')
param adminUsername string = 'azureadmin'

@secure()
@description('Admin password — use Key Vault reference in production')
param adminPassword string

// ── Variables ───────────────────────────────────────────────────────────────

var vmSku = environment == 'prod' ? 'Standard_D2s_v5' : 'Standard_B2s'
var instanceCount = environment == 'prod' ? 3 : 2

// ── Web Tier VMSS ──────────────────────────────────────────────────────────

resource webVmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${orgPrefix}-vmss-web-${environment}'
  location: location
  tags: tags
  sku: {
    name: vmSku
    tier: 'Standard'
    capacity: instanceCount
  }
  zones: ['1', '2', '3']
  properties: {
    overprovision: false
    upgradePolicy: {
      mode: 'Rolling'
      rollingUpgradePolicy: {
        maxBatchInstancePercent: 33
        maxUnhealthyInstancePercent: 33
        maxUnhealthyUpgradedInstancePercent: 33
        pauseTimeBetweenBatches: 'PT10S'
      }
    }
    automaticRepairsPolicy: {
      enabled: true
      gracePeriod: 'PT30M'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: 'web'
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: {
          disablePasswordAuthentication: false
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            assessmentMode: 'AutomaticByPlatform'
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'web-nic'
            properties: {
              primary: true
              enableAcceleratedNetworking: true
              ipConfigurations: [
                {
                  name: 'web-ipconfig'
                  properties: {
                    primary: true
                    subnet: { id: webSubnetId }
                    loadBalancerBackendAddressPools: [
                      { id: webLbBackendPoolId }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'InstallNginx'
            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              type: 'CustomScript'
              typeHandlerVersion: '2.1'
              autoUpgradeMinorVersion: true
              settings: {
                commandToExecute: 'apt-get update && apt-get install -y nginx && systemctl enable nginx && echo "healthy" > /var/www/html/health'
              }
            }
          }
          {
            name: 'HealthExtension'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'http'
                port: 80
                requestPath: '/health'
              }
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
    }
  }
}

// ── App Tier VMSS ──────────────────────────────────────────────────────────

resource appVmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${orgPrefix}-vmss-app-${environment}'
  location: location
  tags: tags
  sku: {
    name: vmSku
    tier: 'Standard'
    capacity: instanceCount
  }
  zones: ['1', '2', '3']
  properties: {
    overprovision: false
    upgradePolicy: {
      mode: 'Rolling'
      rollingUpgradePolicy: {
        maxBatchInstancePercent: 33
        maxUnhealthyInstancePercent: 33
        maxUnhealthyUpgradedInstancePercent: 33
        pauseTimeBetweenBatches: 'PT10S'
      }
    }
    automaticRepairsPolicy: {
      enabled: true
      gracePeriod: 'PT30M'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: 'app'
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: {
          disablePasswordAuthentication: false
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            assessmentMode: 'AutomaticByPlatform'
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'app-nic'
            properties: {
              primary: true
              enableAcceleratedNetworking: true
              ipConfigurations: [
                {
                  name: 'app-ipconfig'
                  properties: {
                    primary: true
                    subnet: { id: appSubnetId }
                    loadBalancerBackendAddressPools: [
                      { id: appLbBackendPoolId }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'InstallAppRuntime'
            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              type: 'CustomScript'
              typeHandlerVersion: '2.1'
              autoUpgradeMinorVersion: true
              settings: {
                commandToExecute: 'apt-get update && apt-get install -y default-jdk && echo "App tier initialized"'
              }
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
    }
  }
}

// ── Autoscale: Web Tier ────────────────────────────────────────────────────

resource webAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${orgPrefix}-autoscale-web-${environment}'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: webVmss.id
    profiles: [
      {
        name: 'DefaultProfile'
        capacity: {
          minimum: '2'
          maximum: environment == 'prod' ? '10' : '4'
          default: string(instanceCount)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: webVmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 75
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
              metricName: 'Percentage CPU'
              metricResourceUri: webVmss.id
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

// ── Outputs ────────────────────────────────────────────────────────────────

output webVmssId string = webVmss.id
output appVmssId string = appVmss.id
