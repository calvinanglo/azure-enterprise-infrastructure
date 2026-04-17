// ============================================================================
// Resource Group Lock — deployable at resourceGroup scope
// AZ-104 Domain: Identity & Governance — Resource Locks
// ============================================================================
// This small module exists solely so a subscription-scoped orchestrator
// (governance.bicep) can place locks on individual resource groups. Bicep
// requires that a resource's scope match the scope of the Bicep file
// deploying it; to lock an RG from a subscription-scoped template you must
// indirect through a resourceGroup-scoped module like this one.

targetScope = 'resourceGroup'

// Name of the lock resource — must be unique within the RG. By convention:
//   lock-<purpose>-<level>  e.g. lock-networking-nodelete
param lockName string

// Lock level: 'CanNotDelete' allows modifications but blocks deletion;
// 'ReadOnly' blocks both modifications and deletion. Owner / User Access
// Administrator are the only built-in roles that can create or remove locks.
@allowed([
  'CanNotDelete'
  'ReadOnly'
])
param lockLevel string

// Free-form note displayed in the portal Lock details blade. Use it to
// document why the lock exists and whom to contact for removal.
param notes string

resource lock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: lockName
  properties: {
    level: lockLevel
    notes: notes
  }
}
