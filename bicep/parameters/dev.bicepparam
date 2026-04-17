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

// VMSS admin password — read from the VM_ADMIN_PASSWORD environment variable
// at deployment time. The fallback placeholder is used only for `bicep build`
// validation and what-if dry runs in CI; a real deployment MUST set the env
// var (GitHub Actions secret) or replace this with a Key Vault reference:
//   param adminPassword = az.getSecret('<sub>', '<rg>', '<vault>', 'vm-admin')
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', 'CiPlaceholder!DoNotUseInProd123')
