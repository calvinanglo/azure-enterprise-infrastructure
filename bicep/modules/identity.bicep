// ============================================================================
// Identity — Custom RBAC roles scoped to least-privilege
// ============================================================================

targetScope = 'subscription'

param environment string
param computeResourceGroupId string
param networkingResourceGroupId string
param monitoringResourceGroupId string

// ── Custom Role: VM Operator ───────────────────────────────────────────────
// Can start/stop/restart VMs but NOT delete or create them

resource vmOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  name: guid(subscription().id, 'vm-operator-${environment}')
  properties: {
    roleName: 'VM Operator (${environment})'
    description: 'Start, stop, restart, and read VMs. Cannot create or delete.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/virtualMachines/read'
          'Microsoft.Compute/virtualMachines/start/action'
          'Microsoft.Compute/virtualMachines/restart/action'
          'Microsoft.Compute/virtualMachines/deallocate/action'
          'Microsoft.Compute/virtualMachines/powerOff/action'
          'Microsoft.Compute/virtualMachineScaleSets/read'
          'Microsoft.Compute/virtualMachineScaleSets/start/action'
          'Microsoft.Compute/virtualMachineScaleSets/restart/action'
          'Microsoft.Compute/virtualMachineScaleSets/deallocate/action'
          'Microsoft.Compute/virtualMachineScaleSets/powerOff/action'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/start/action'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/restart/action'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/deallocate/action'
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/powerOff/action'
          'Microsoft.Network/networkInterfaces/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      computeResourceGroupId
    ]
  }
}

// ── Custom Role: Network Viewer ────────────────────────────────────────────
// Read-only on all networking + NSG flow logs

resource networkViewerRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  name: guid(subscription().id, 'network-viewer-${environment}')
  properties: {
    roleName: 'Network Viewer (${environment})'
    description: 'Read-only access to VNets, NSGs, route tables, and flow logs.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Network/networkSecurityGroups/read'
          'Microsoft.Network/networkSecurityGroups/securityRules/read'
          'Microsoft.Network/routeTables/read'
          'Microsoft.Network/routeTables/routes/read'
          'Microsoft.Network/publicIPAddresses/read'
          'Microsoft.Network/loadBalancers/read'
          'Microsoft.Network/azureFirewalls/read'
          'Microsoft.Network/bastionHosts/read'
          'Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read'
          'Microsoft.Network/networkWatchers/read'
          'Microsoft.Network/networkWatchers/flowLogs/read'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      networkingResourceGroupId
    ]
  }
}

// ── Custom Role: Monitoring Reader+ ────────────────────────────────────────
// Read monitoring data + manage alert rules (but not action groups)

resource monitoringReaderPlusRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  name: guid(subscription().id, 'monitoring-reader-plus-${environment}')
  properties: {
    roleName: 'Monitoring Reader Plus (${environment})'
    description: 'Read monitoring data and manage alert rules. Cannot modify action groups or diagnostic settings.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Insights/metrics/read'
          'Microsoft.Insights/logs/read'
          'Microsoft.Insights/metricAlerts/*'
          'Microsoft.Insights/scheduledQueryRules/*'
          'Microsoft.OperationalInsights/workspaces/read'
          'Microsoft.OperationalInsights/workspaces/query/read'
          'Microsoft.OperationalInsights/workspaces/analytics/query/action'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: [
          'Microsoft.Insights/actionGroups/write'
          'Microsoft.Insights/actionGroups/delete'
          'Microsoft.Insights/diagnosticSettings/write'
        ]
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      monitoringResourceGroupId
    ]
  }
}
