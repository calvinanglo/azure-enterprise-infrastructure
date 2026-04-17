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

// VMSS admin password — in production, ALWAYS source from Key Vault.
// Replace this with an az.getSecret() reference once the vault exists, e.g.
//   param adminPassword = az.getSecret('<sub>', '<rg>', '<vault>', 'vm-admin')
// The env var fallback exists only so `bicep build` and what-if dry runs
// complete without a live vault lookup.
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', 'ProdPlaceholder!ReplaceWithKeyVault123')
