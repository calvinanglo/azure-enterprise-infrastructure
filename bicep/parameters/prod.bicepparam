using '../main.bicep'

param location = 'eastus2'
param environment = 'prod'
param orgPrefix = 'ent'
param globalTags = {
  Environment: 'prod'
  ManagedBy: 'Bicep'
  Project: 'enterprise-infra'
  CostCenter: 'IT-OPS-001'
}
