// ============================================================================
// Monitoring — Log Analytics, alerts, action groups, dashboard
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object

// ── Log Analytics Workspace ────────────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${orgPrefix}-law-${environment}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: environment == 'prod' ? 90 : 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: environment == 'prod' ? 10 : 5
    }
  }
}

// ── Action Group (email + webhook) ─────────────────────────────────────────

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${orgPrefix}-ag-critical-${environment}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'CritAlert'
    enabled: true
    emailReceivers: [
      {
        name: 'InfraTeam'
        emailAddress: 'infra-alerts@company.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ── Alert: High CPU on VMSS ────────────────────────────────────────────────

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${orgPrefix}-alert-high-cpu-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      subscription().id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
    description: 'Fires when average CPU exceeds 85% over 15 minutes'
  }
}

// ── Alert: VM Availability < 100% ──────────────────────────────────────────

resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${orgPrefix}-alert-vm-availability-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 1
    enabled: true
    scopes: [
      subscription().id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'VMAvailabilityDrop'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'VmAvailabilityMetric'
          metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
    description: 'Fires when VM availability drops below 100%'
  }
}

// ── Scheduled Query: NSG Deny Events ───────────────────────────────────────

resource nsgDenyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${orgPrefix}-alert-nsg-deny-spike-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 3
    enabled: true
    evaluationFrequency: 'PT10M'
    windowSize: 'PT30M'
    scopes: [
      logAnalytics.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
            AzureNetworkAnalytics_CL
            | where FlowStatus_s == "D"
            | summarize DenyCount = count() by bin(TimeGenerated, 10m), NSGRule_s
            | where DenyCount > 100
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    description: 'Fires when >100 NSG deny events occur in 10 minutes'
  }
}

// ── Log Analytics Solutions ────────────────────────────────────────────────

resource vmInsights 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'VMInsights(${logAnalytics.name})'
  location: location
  tags: tags
  plan: {
    name: 'VMInsights(${logAnalytics.name})'
    publisher: 'Microsoft'
    product: 'OMSGallery/VMInsights'
    promotionCode: ''
  }
  properties: {
    workspaceResourceId: logAnalytics.id
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output workspaceId string = logAnalytics.id
output workspaceName string = logAnalytics.name
output actionGroupId string = actionGroup.id
