// ============================================================================
// Governance — Azure Policy assignments, resource locks, tagging enforcement
// AZ-104 Domain: Manage Azure identities and governance (15–20%)
// Azure Policy evaluates resources against rules (definitions) and reports
// compliance or blocks non-compliant deployments. Resource locks prevent
// accidental deletion or modification of critical resources.
// ============================================================================

// Subscription-scoped deployment: policy assignments and locks apply to the
// entire subscription unless scoped further via the 'scope' property.
targetScope = 'subscription'

// -- Parameters ---------------------------------------------------------------

// Deployment environment (dev / staging / prod) — several policies use this
// to toggle between enforcement modes (prod = enforced, non-prod = audit-only)
param environment string

// Array of resource group names managed by this subscription. Index positions
// are fixed by convention: [0] = networking, [3] = security, [4] = monitoring.
// Used to scope resource locks to specific resource groups.
param resourceGroupNames array

// ── Policy: Require Tags ───────────────────────────────────────────────────
// Tagging policies ensure every resource carries metadata required for cost
// allocation, CMDB population, and compliance reporting. Without enforced tags
// it is impossible to attribute costs to teams or projects accurately.

resource requireEnvironmentTag 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  // Assignment name must be unique within the scope; used in ARM resource IDs
  name: 'require-environment-tag'
  properties: {
    // Human-readable name shown in the Azure portal compliance dashboard
    displayName: 'Require Environment tag on all resources'
    // Built-in policy definition: "Require a tag and its value on resources"
    // This definition ID is stable across all Azure tenants (built-in)
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'  // Require a tag and its value
    parameters: {
      // tagName specifies which tag key the policy checks for
      tagName: { value: 'Environment' }
      // tagValue specifies the required value for that tag; must match the
      // environment parameter so each deployment enforces its own value
      tagValue: { value: environment }
    }
    // 'Default' = actively deny or remediate non-compliant resources (enforced).
    // 'DoNotEnforce' = audit-only; non-compliant resources are flagged but not
    // blocked. Non-prod environments use DoNotEnforce to avoid blocking dev work.
    enforcementMode: environment == 'prod' ? 'Default' : 'DoNotEnforce'
    // Description is surfaced in compliance reports and policy details blade
    description: 'Enforces Environment tag on all resources in this subscription'
  }
}

resource requireCostCenterTag 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-costcenter-tag'
  properties: {
    displayName: 'Require CostCenter tag on resource groups'
    // Built-in policy: "Require a tag on resource groups"
    // Scoped to resource groups (not individual resources), ensuring every RG
    // carries a CostCenter tag for chargeback/showback reporting
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'  // Require a tag on resource groups
    parameters: {
      // Only the tag key is required here; the value is free-form (team/project code)
      tagName: { value: 'CostCenter' }
    }
    // Always enforced regardless of environment — resource group creation will
    // be blocked if CostCenter tag is missing
    enforcementMode: 'Default'
    description: 'Ensures all resource groups have a CostCenter tag for billing'
  }
}

// ── Policy: Allowed Locations ──────────────────────────────────────────────
// Restricts where resources can be deployed. Important for data residency
// compliance (e.g. GDPR), latency optimization, and cost control.
// Resources deployed outside approved regions will be blocked on creation.

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'allowed-locations'
  properties: {
    displayName: 'Restrict resource deployment to approved regions'
    // Built-in policy: "Allowed locations" — blocks resource creation in
    // any region not in the listOfAllowedLocations parameter
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
    parameters: {
      listOfAllowedLocations: {
        // Three US regions approved for this subscription. Global resources
        // (DNS zones, AAD objects) are exempt from location policies.
        value: [
          'eastus2'    // Primary region: low latency to US East operations
          'centralus'  // Secondary region: used for geo-redundant pairs
          'westus2'    // Tertiary region: DR or West Coast proximity
        ]
      }
    }
    // Always enforced — deployment to unapproved regions is denied outright
    enforcementMode: 'Default'
    description: 'Only East US 2, Central US, West US 2 allowed'
  }
}

// ── Policy: Deny Public IP on NICs ─────────────────────────────────────────
// Prevents VMs from having directly attached public IPs on their NICs.
// All internet-facing access must go through the load balancer or Azure Bastion.
// This is a defense-in-depth control: even if a VM is misconfigured, it cannot
// be reached directly from the internet.

resource denyPublicIp 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-nic-public-ip'
  properties: {
    displayName: 'Deny public IP addresses on VM network interfaces'
    // Built-in policy that blocks NIC resources with a public IP association
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114'
    // Enforced only in prod — dev/staging environments may need direct VM access
    // during development and debugging workflows
    enforcementMode: environment == 'prod' ? 'Default' : 'DoNotEnforce'
    description: 'Prevents VMs from having public IPs — all access via Bastion or LB'
  }
}

// ── Policy: Require Storage HTTPS ──────────────────────────────────────────
// Ensures all Azure Storage accounts enforce HTTPS (secure transfer required).
// HTTP access to storage is unencrypted and fails compliance checks for
// PCI-DSS, HIPAA, and most organizational security baselines.

resource storageHttps 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'storage-require-https'
  properties: {
    displayName: 'Storage accounts must use HTTPS'
    // Built-in policy: "Secure transfer to storage accounts should be enabled"
    // Audits (or denies, depending on the definition effect) storage accounts
    // that do not have supportsHttpsTrafficOnly = true
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9'
    // Always enforced — HTTP-only storage is never acceptable in any environment
    enforcementMode: 'Default'
    description: 'Audit/deny storage accounts not enforcing HTTPS'
  }
}

// ── Resource Locks (production only) ───────────────────────────────────────
// Resource locks prevent accidental deletion or modification of critical
// infrastructure. Two lock levels exist:
//   'CanNotDelete' — resources can be read and modified, but not deleted
//   'ReadOnly'     — resources can only be read; no modifications or deletions
// Locks apply to the entire resource group and all resources within it.
// Only Owner or User Access Administrator roles can create/remove locks.
// The 'if (environment == "prod")' condition skips lock creation in non-prod
// environments where developers need to freely create and delete resources.

// Locks that target a different scope than the enclosing Bicep file must be
// deployed via a nested module. The sub-module `rg-lock.bicep` runs at
// resourceGroup scope; this governance module runs at subscription scope.

// Networking resource group lock — prevents accidental deletion of VNets,
// NSGs, route tables, and other networking infrastructure that would take
// down all application connectivity if removed
module networkingLock 'rg-lock.bicep' = if (environment == 'prod') {
  name: 'deploy-lock-networking'
  // scope targets a specific resource group by name from the parameter array;
  // index [0] = networking RG by convention
  scope: resourceGroup(resourceGroupNames[0])
  params: {
    lockName: 'lock-networking-nodelete'
    // CanNotDelete: admins can still modify network configurations (add routes,
    // update NSG rules) but cannot delete the RG or its resources
    lockLevel: 'CanNotDelete'
    notes: 'Production networking resources — cannot be deleted without removing lock first'
  }
}

// Security resource group lock — protects Key Vault and related security
// resources. Accidental deletion of Key Vault would break all applications
// that rely on stored secrets, keys, and certificates.
module securityLock 'rg-lock.bicep' = if (environment == 'prod') {
  name: 'deploy-lock-security'
  // index [3] = security RG by convention (Key Vault, managed identities)
  scope: resourceGroup(resourceGroupNames[3])
  params: {
    lockName: 'lock-security-nodelete'
    // CanNotDelete: still allows secret rotation and vault configuration changes
    lockLevel: 'CanNotDelete'
    notes: 'Key Vault and security resources — protected from accidental deletion'
  }
}

// Monitoring resource group lock — set to ReadOnly because monitoring config
// drift (e.g. someone deleting a Log Analytics workspace) can silently break
// alerting and audit logging. ReadOnly prevents any changes without explicit
// lock removal, which is a deliberate, auditable action.
module monitoringLock 'rg-lock.bicep' = if (environment == 'prod') {
  name: 'deploy-lock-monitoring'
  // index [4] = monitoring RG by convention (Log Analytics, dashboards, alerts)
  scope: resourceGroup(resourceGroupNames[4])
  params: {
    lockName: 'lock-monitoring-readonly'
    // ReadOnly: prevents all write operations on the monitoring RG resources;
    // any changes require removing this lock first (creates an audit trail)
    lockLevel: 'ReadOnly'
    notes: 'Monitoring workspace — read-only to prevent config drift'
  }
}
