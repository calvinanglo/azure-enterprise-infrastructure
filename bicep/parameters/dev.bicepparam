using '../main.bicep'

param location = 'eastus2'
param environment = 'dev'
param orgPrefix = 'ent'
param globalTags = {
  Environment: 'dev'
  ManagedBy: 'Bicep'
  Project: 'enterprise-infra'
  CostCenter: 'IT-DEV-002'
}
