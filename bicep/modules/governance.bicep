// ============================================================================
// Governance — Azure Policy assignments, resource locks, tagging enforcement
// ============================================================================

targetScope = 'subscription'

param environment string
param resourceGroupNames array

// ── Policy: Require Tags ───────────────────────────────────────────────────

resource requireEnvironmentTag 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-environment-tag'
  properties: {
    displayName: 'Require Environment tag on all resources'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'  // Require a tag and its value
    parameters: {
      tagName: { value: 'Environment' }
      tagValue: { value: environment }
    }
    enforcementMode: environment == 'prod' ? 'Default' : 'DoNotEnforce'
    description: 'Enforces Environment tag on all resources in this subscription'
  }
}

resource requireCostCenterTag 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-costcenter-tag'
  properties: {
    displayName: 'Require CostCenter tag on resource groups'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'  // Require a tag on resource groups
    parameters: {
      tagName: { value: 'CostCenter' }
    }
    enforcementMode: 'Default'
    description: 'Ensures all resource groups have a CostCenter tag for billing'
  }
}

// ── Policy: Allowed Locations ──────────────────────────────────────────────

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'allowed-locations'
  properties: {
    displayName: 'Restrict resource deployment to approved regions'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
    parameters: {
      listOfAllowedLocations: {
        value: [
          'eastus2'
          'centralus'
          'westus2'
        ]
      }
    }
    enforcementMode: 'Default'
    description: 'Only East US 2, Central US, West US 2 allowed'
  }
}

// ── Policy: Deny Public IP on NICs ─────────────────────────────────────────

resource denyPublicIp 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-nic-public-ip'
  properties: {
    displayName: 'Deny public IP addresses on VM network interfaces'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114'
    enforcementMode: environment == 'prod' ? 'Default' : 'DoNotEnforce'
    description: 'Prevents VMs from having public IPs — all access via Bastion or LB'
  }
}

// ── Policy: Require Storage HTTPS ──────────────────────────────────────────

resource storageHttps 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'storage-require-https'
  properties: {
    displayName: 'Storage accounts must use HTTPS'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9'
    enforcementMode: 'Default'
    description: 'Audit/deny storage accounts not enforcing HTTPS'
  }
}

// ── Resource Locks (production only) ───────────────────────────────────────

resource networkingLock 'Microsoft.Authorization/locks@2020-05-01' = if (environment == 'prod') {
  name: 'lock-networking-nodelete'
  scope: resourceGroup(resourceGroupNames[0])
  properties: {
    level: 'CanNotDelete'
    notes: 'Production networking resources — cannot be deleted without removing lock first'
  }
}

resource securityLock 'Microsoft.Authorization/locks@2020-05-01' = if (environment == 'prod') {
  name: 'lock-security-nodelete'
  scope: resourceGroup(resourceGroupNames[3])
  properties: {
    level: 'CanNotDelete'
    notes: 'Key Vault and security resources — protected from accidental deletion'
  }
}

resource monitoringLock 'Microsoft.Authorization/locks@2020-05-01' = if (environment == 'prod') {
  name: 'lock-monitoring-readonly'
  scope: resourceGroup(resourceGroupNames[4])
  properties: {
    level: 'ReadOnly'
    notes: 'Monitoring workspace — read-only to prevent config drift'
  }
}
