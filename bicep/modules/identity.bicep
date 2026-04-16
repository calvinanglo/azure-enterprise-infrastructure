// ============================================================================
// Identity — Custom RBAC roles scoped to least-privilege
// AZ-104 Domain: Manage Azure identities and governance (15–20%)
// Custom roles follow the principle of least privilege: grant only the specific
// actions required for a job function, nothing more. They are defined once at
// subscription scope and then assigned to users, groups, or managed identities
// at whatever scope is appropriate (subscription, RG, or resource).
// ============================================================================

// Custom role definitions must be created at subscription scope so they can
// be assigned at any scope within (or below) the subscription
targetScope = 'subscription'

// -- Parameters ---------------------------------------------------------------

// Deployment environment — included in role names and GUIDs to allow parallel
// role definitions across dev/staging/prod without name collisions
param environment string

// ARM resource ID of the compute resource group; used as the assignable scope
// for the VM Operator role so the role can only be granted within that RG
param computeResourceGroupId string

// ARM resource ID of the networking resource group; used as the assignable scope
// for the Network Viewer role, limiting where it can be assigned
param networkingResourceGroupId string

// ARM resource ID of the monitoring resource group; used as the assignable
// scope for the Monitoring Reader Plus role
param monitoringResourceGroupId string

// ── Custom Role: VM Operator ───────────────────────────────────────────────
// Can start/stop/restart VMs but NOT delete or create them
// This role is appropriate for operations teams who need to manage VM power
// state (e.g. scheduled start/stop for cost savings) without the risk of
// accidentally deleting or reconfiguring virtual machines.

resource vmOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  // guid() generates a deterministic UUID from the inputs; subscription().id +
  // a unique string ensures this role has a stable, unique ID that does not
  // change across re-deployments but differs from roles in other environments
  name: guid(subscription().id, 'vm-operator-${environment}')
  properties: {
    // roleName is the display name shown in the portal RBAC assignment blade;
    // including environment prevents confusion between dev/prod operator roles
    roleName: 'VM Operator (${environment})'
    // description appears in the role details blade and in access reviews
    description: 'Start, stop, restart, and read VMs. Cannot create or delete.'
    // 'CustomRole' distinguishes this from built-in roles; the only valid value
    // for custom role definitions
    type: 'CustomRole'
    permissions: [
      {
        // actions is the allow-list of Azure Resource Manager (ARM) control-plane
        // operations this role grants. Uses the format: provider/resource/operation
        actions: [
          // Read VM properties (size, status, disks) — required for portal visibility
          'Microsoft.Compute/virtualMachines/read'
          // Power on a deallocated or stopped VM
          'Microsoft.Compute/virtualMachines/start/action'
          // Reboot a running VM without deallocating it
          'Microsoft.Compute/virtualMachines/restart/action'
          // Gracefully shut down and deallocate the VM (stops billing for compute)
          'Microsoft.Compute/virtualMachines/deallocate/action'
          // Power off the VM OS without deallocating (billing continues — guest OS shutdown)
          'Microsoft.Compute/virtualMachines/powerOff/action'
          // Read VMSS (Virtual Machine Scale Set) configuration and instance list
          'Microsoft.Compute/virtualMachineScaleSets/read'
          // Start all instances in a VMSS (or a subset via instance IDs)
          'Microsoft.Compute/virtualMachineScaleSets/start/action'
          // Restart all instances in a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/restart/action'
          // Deallocate all instances in a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/deallocate/action'
          // Power off all instances in a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/powerOff/action'
          // Read individual VM instances within a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read'
          // Start a specific VM instance within a VMSS by instance ID
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/start/action'
          // Restart a specific VM instance within a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/restart/action'
          // Deallocate a specific VM instance within a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/deallocate/action'
          // Power off a specific VM instance within a VMSS
          'Microsoft.Compute/virtualMachineScaleSets/virtualMachines/powerOff/action'
          // Read NIC properties (IP addresses, subnet associations) — needed
          // to identify which network a VM is connected to
          'Microsoft.Network/networkInterfaces/read'
          // Read resource group metadata — required for portal navigation and
          // to list resources within the assigned scope
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        // notActions explicitly removes actions from the allow-list (deny overrides).
        // Empty here — all unlisted actions (e.g. delete, write) are implicitly denied.
        notActions: []
        // dataActions control access to data-plane operations (e.g. reading blob
        // contents). Empty — this role is control-plane only.
        dataActions: []
        // notDataActions explicitly removes data-plane actions. Empty here.
        notDataActions: []
      }
    ]
    // assignableScopes limits where this role CAN BE ASSIGNED (not where it is
    // currently assigned). Scoping to a single RG prevents this role from being
    // accidentally assigned at subscription scope, which would be too broad.
    assignableScopes: [
      computeResourceGroupId
    ]
  }
}

// ── Custom Role: Network Viewer ────────────────────────────────────────────
// Read-only on all networking + NSG flow logs
// Appropriate for security analysts and network engineers who need visibility
// into network topology and traffic patterns without the ability to make changes.

resource networkViewerRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  // Deterministic GUID unique to this environment's Network Viewer role
  name: guid(subscription().id, 'network-viewer-${environment}')
  properties: {
    roleName: 'Network Viewer (${environment})'
    description: 'Read-only access to VNets, NSGs, route tables, and flow logs.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          // Read VNet address spaces, DNS settings, and peering configuration
          'Microsoft.Network/virtualNetworks/read'
          // Read individual subnet definitions (address prefixes, NSG associations,
          // service endpoint configurations, delegation settings)
          'Microsoft.Network/virtualNetworks/subnets/read'
          // Read NSG resource (name, associated subnets/NICs, provisioning state)
          'Microsoft.Network/networkSecurityGroups/read'
          // Read individual NSG rules (priority, protocol, port, allow/deny)
          'Microsoft.Network/networkSecurityGroups/securityRules/read'
          // Read route table resource and its association with subnets
          'Microsoft.Network/routeTables/read'
          // Read individual UDR (User Defined Route) entries within a route table
          'Microsoft.Network/routeTables/routes/read'
          // Read public IP address allocation method, IP address, DNS label
          'Microsoft.Network/publicIPAddresses/read'
          // Read load balancer frontend IPs, backend pools, health probes, rules
          'Microsoft.Network/loadBalancers/read'
          // Read Azure Firewall policies, rule collections, and threat intel settings
          'Microsoft.Network/azureFirewalls/read'
          // Read Azure Bastion host configuration (SKU, IP config, scaling)
          'Microsoft.Network/bastionHosts/read'
          // Read VNet peering connections (remote VNet, state, traffic settings)
          'Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read'
          // Read Network Watcher resource (exists per region, per subscription)
          'Microsoft.Network/networkWatchers/read'
          // Read NSG flow log configuration (storage account, retention, version)
          'Microsoft.Network/networkWatchers/flowLogs/read'
          // Read resource group metadata — required for portal navigation
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        // No actions are denied beyond what is implicitly excluded; this role
        // is purely read-only — no write/action permissions are included above
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    // Scoped to the networking RG only; cannot be assigned to compute or
    // other resource groups, keeping its blast radius small
    assignableScopes: [
      networkingResourceGroupId
    ]
  }
}

// ── Custom Role: Monitoring Reader+ ────────────────────────────────────────
// Read monitoring data + manage alert rules (but not action groups)
// Designed for NOC (Network Operations Center) or SRE teams who need to view
// dashboards, run log queries, and tune alert thresholds, but should not be
// able to change where alerts are sent (action groups) or alter diagnostic
// settings that feed data into the workspace.

resource monitoringReaderPlusRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  // Deterministic GUID unique to this environment's Monitoring Reader Plus role
  name: guid(subscription().id, 'monitoring-reader-plus-${environment}')
  properties: {
    roleName: 'Monitoring Reader Plus (${environment})'
    description: 'Read monitoring data and manage alert rules. Cannot modify action groups or diagnostic settings.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          // Read platform metrics from any resource (CPU, memory, disk, network)
          'Microsoft.Insights/metrics/read'
          // Read log data from Log Analytics workspaces (KQL query results)
          'Microsoft.Insights/logs/read'
          // Full control over metric alert rules (static threshold and dynamic
          // threshold alerts); wildcard (*) covers read/write/delete on metricAlerts
          'Microsoft.Insights/metricAlerts/*'
          // Full control over scheduled query rules (log-based alert rules that
          // run KQL queries on a schedule); covers read/write/delete
          'Microsoft.Insights/scheduledQueryRules/*'
          // Read Log Analytics workspace resource metadata (workspace ID, SKU, retention)
          'Microsoft.OperationalInsights/workspaces/read'
          // Execute read-only KQL queries against workspace log tables
          'Microsoft.OperationalInsights/workspaces/query/read'
          // Execute analytics queries (advanced KQL analysis features)
          'Microsoft.OperationalInsights/workspaces/analytics/query/action'
          // Read resource group metadata — required for portal navigation
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        // notActions removes specific operations from the allow-list above.
        // These three exclusions prevent this role from escalating its own
        // alert notifications or altering what data flows into the workspace:
        notActions: [
          // Cannot create or modify action groups (email/SMS/webhook alert targets);
          // ensures alert notifications cannot be hijacked or silenced
          'Microsoft.Insights/actionGroups/write'
          // Cannot delete action groups; prevents disruption of existing alert routing
          'Microsoft.Insights/actionGroups/delete'
          // Cannot modify diagnostic settings; prevents disabling audit log collection
          // which would create blind spots in the monitoring pipeline
          'Microsoft.Insights/diagnosticSettings/write'
        ]
        dataActions: []
        notDataActions: []
      }
    ]
    // Scoped to the monitoring RG; this role cannot be assigned to compute or
    // networking resource groups, preventing accidental broad access grants
    assignableScopes: [
      monitoringResourceGroupId
    ]
  }
}
