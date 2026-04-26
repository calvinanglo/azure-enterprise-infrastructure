// ============================================================================
// Enterprise Multi-Tier Infrastructure — Orchestrator
// Deploys hub-spoke networking, compute, storage, identity, governance,
// and monitoring in a single subscription scope.
// ============================================================================
// AZ-104 context: Subscription-scoped deployments are used when you need to
// create and manage multiple resource groups from a single ARM/Bicep template.
// This mirrors what an Azure Administrator does when standing up a full
// workload environment: networking, compute, storage, security, and governance
// are each isolated into their own resource group for RBAC and lifecycle
// management purposes.
// ============================================================================

// targetScope instructs the ARM runtime to evaluate this deployment at the
// subscription level rather than a resource group. This is required when the
// template itself creates resource groups (Microsoft.Resources/resourceGroups).
// AZ-104: Understand the four scope levels — management group, subscription,
// resource group, and resource. Subscription scope is needed here because
// resource groups are child objects of a subscription.
targetScope = 'subscription'

// ── Parameters ──────────────────────────────────────────────────────────────

// location: The Azure region where all resource groups and resources will be
// created. Centralizing this as a parameter avoids hard-coding region names
// in every module and makes multi-region deployments easier to manage.
@description('Primary Azure region')
param location string

// environment: Enforces a controlled set of allowed values using the @allowed
// decorator. This prevents accidental deployments with typos (e.g., "prod ")
// and maps directly to naming conventions and tier-specific configurations
// in each module. AZ-104: environments should map to separate subscriptions
// or at minimum separate resource groups to isolate blast radius.
@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string

// orgPrefix: Short organizational identifier prepended to all resource names.
// Azure resource names must be globally unique for some types (e.g., storage
// accounts, Key Vaults). Using a consistent prefix with length constraints
// prevents names from exceeding Azure's per-resource character limits.
// @minLength and @maxLength are compile-time validators enforced by Bicep.
@description('Organization prefix for resource naming')
@minLength(2)
@maxLength(5)
param orgPrefix string = 'ent'

// deploymentTimestamp: A UTC timestamp injected at deployment time using the
// utcNow() function. Used to make deployment names unique (required by ARM
// for idempotent re-deployments) and to stamp resources with their creation
// time via globalTags. utcNow() can only be used as a parameter default.
@description('Deployment timestamp for unique naming')
param deploymentTimestamp string = utcNow('yyyyMMddHHmm')

// globalTags: An object literal applied to every resource group and module
// call. AZ-104: Consistent tagging is a governance requirement for cost
// management (Cost Center), environment segregation, and Azure Policy
// compliance. Tags are key-value metadata stored on the ARM resource object.
// CostCenter enables Azure Cost Management + Billing to split charges by
// team. DeployedOn supports auditing and lifecycle management.
@description('Tags applied to every resource')
param globalTags object = {
  Environment: environment
  ManagedBy: 'Bicep'
  Project: 'enterprise-infra'
  CostCenter: 'IT-OPS'
  DeployedOn: deploymentTimestamp
}

// VMSS admin password — @secure() prevents the value from appearing in
// deployment history or ARM logs. In production, source this from a Key Vault
// reference in the parameter file or inject from the CI/CD pipeline via a
// secure environment variable (e.g. GitHub Actions secrets).
@secure()
@description('Admin password for VMSS instances — inject from Key Vault or pipeline secret')
param adminPassword string

// Existing-resource-name overrides — supplied by parameter files when the
// storage account or Key Vault was created outside this Bicep template (for
// example via an earlier portal deployment). Empty string = let Bicep generate
// a new globally-unique name; non-empty = pin to that exact name so the
// deployment updates the existing resource in place rather than creating a
// duplicate. Required because uniqueString() is deterministic per-input but
// produces different output than was used at original creation time.
@description('Existing storage account name to update in place; empty = generate a new name')
param existingStorageAccountName string = ''

@description('Existing Key Vault name to update in place; empty = generate a new name')
param existingKeyVaultName string = ''

// ── Variables ───────────────────────────────────────────────────────────────

// resourceGroupNames: A single object variable that consolidates all resource
// group name strings. Defining them once here prevents inconsistencies between
// module calls and the teardown script. The naming pattern follows the Azure
// CAF (Cloud Adoption Framework) recommendation:
//   <prefix>-rg-<workload>-<environment>
// Each workload pillar gets its own resource group so that RBAC assignments,
// resource locks, and deletion operations are scoped to a logical boundary.
var resourceGroupNames = {
  networking: '${orgPrefix}-rg-networking-${environment}'
  compute: '${orgPrefix}-rg-compute-${environment}'
  storage: '${orgPrefix}-rg-storage-${environment}'
  security: '${orgPrefix}-rg-security-${environment}'
  monitoring: '${orgPrefix}-rg-monitoring-${environment}'
}

// ── Resource Groups ─────────────────────────────────────────────────────────
// AZ-104: Resource groups are logical containers that hold related Azure
// resources. They share a lifecycle — deleting a resource group deletes
// everything in it. Separating networking from compute (for example) ensures
// that a compute teardown does not inadvertently remove shared VNet resources.
// All resource groups are created in the same region as the resources they
// will contain, which satisfies ARM metadata locality requirements.

// rgNetworking: Contains VNets, subnets, NSGs, route tables, Azure Firewall,
// VPN Gateway, Bastion, and peering configurations. Isolated so that network
// engineers can be granted scoped RBAC (e.g., Network Contributor) without
// touching compute or storage resources.
resource rgNetworking 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.networking
  location: location
  tags: globalTags
}

// rgCompute: Contains VMSS instances, managed disks, App Service plans,
// container resources, and the Recovery Services Vault. Compute resources
// are the most frequently scaled and updated, so isolating them reduces
// the risk of accidental governance changes to stable infrastructure.
resource rgCompute 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.compute
  location: location
  tags: globalTags
}

// rgStorage: Contains storage accounts and their containers. Isolated to
// allow fine-grained RBAC (e.g., Storage Blob Data Contributor) and to
// apply separate resource locks in production environments.
resource rgStorage 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.storage
  location: location
  tags: globalTags
}

// rgSecurity: Contains Key Vault. Strict RBAC isolation is critical here —
// only privileged identities should have Key Vault Contributor or Secrets
// Officer access. Separating Key Vault into its own resource group makes
// auditing easier and allows a CanNotDelete resource lock in production.
resource rgSecurity 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.security
  location: location
  tags: globalTags
}

// rgMonitoring: Contains the Log Analytics Workspace and any diagnostic
// infrastructure (Azure Monitor, Alerts, Action Groups). Deployed to a
// separate resource group so that monitoring survives independent of the
// workload it observes — a monitoring RG should never be accidentally
// deleted during a compute teardown.
resource rgMonitoring 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupNames.monitoring
  location: location
  tags: globalTags
}

// ── Module: Monitoring (deployed first — other modules send diagnostics here)
// AZ-104: Azure Monitor and Log Analytics are foundational observability
// services. Deploying them first is intentional — every subsequent module
// receives the Log Analytics workspace ID so it can configure diagnostic
// settings (platform metrics and resource logs) at creation time rather than
// as a post-deployment step. This avoids a gap in observability coverage.
// The scope keyword targets the deployment to rgMonitoring so all monitoring
// resources land in the correct resource group.
module monitoring 'modules/monitoring.bicep' = {
  // Deployment name is timestamped to support re-entrant deployments.
  // ARM requires unique deployment names within a scope; the timestamp
  // guarantees uniqueness on repeated runs.
  name: 'deploy-monitoring-${deploymentTimestamp}'
  scope: rgMonitoring
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
  }
}

// ── Module: Key Vault ───────────────────────────────────────────────────────
// AZ-104: Azure Key Vault is the managed secrets store for the platform.
// It stores certificate private keys, storage account connection strings,
// and any other sensitive configuration values that should not appear in
// ARM templates or application code. Deploying Key Vault after monitoring
// allows diagnostic logs (secret access, key operations) to flow to Log
// Analytics from the moment the vault is live.
// logAnalyticsWorkspaceId is passed from the monitoring module's output,
// demonstrating module-to-module output chaining — a key Bicep pattern.
module keyvault 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault-${deploymentTimestamp}'
  scope: rgSecurity  // Scoped to the security resource group for isolation
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // Chain the workspace ID from monitoring so Key Vault sends audit logs
    // (access events, key rotation) to the central Log Analytics workspace.
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    // Reuse the existing vault name (created outside this Bicep) so the
    // deployment updates it in place rather than creating a duplicate.
    existingKeyVaultName: existingKeyVaultName
  }
}

// ── Module: Storage ─────────────────────────────────────────────────────────
// AZ-104: Deploys storage accounts used for application data, VM boot
// diagnostics, and Azure Backup staging. Storage is deployed early because
// compute modules reference the storage account for boot diagnostics URIs.
// Diagnostic settings route Storage Analytics logs (read/write/delete
// transactions) to the central Log Analytics workspace.
module storage 'modules/storage.bicep' = {
  name: 'deploy-storage-${deploymentTimestamp}'
  scope: rgStorage  // Scoped to the dedicated storage resource group
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // Enables Storage diagnostic settings (blob access logs, metrics)
    // to route to the central Log Analytics workspace.
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    // Pin to the pre-existing storage account so the deployment updates it
    // in place rather than provisioning a second account.
    existingStorageAccountName: existingStorageAccountName
  }
}

// ── Module: Hub Network ─────────────────────────────────────────────────────
// AZ-104: Implements the hub VNet in a hub-spoke topology. The hub contains
// shared services: Azure Firewall (for centralized egress inspection and
// forced tunneling), Azure Bastion (secure SSH/RDP without public IPs on
// VMs), VPN or ExpressRoute Gateway (hybrid connectivity), and the
// GatewaySubnet. Hub outputs (VNet ID, Firewall private IP) are consumed by
// the spoke module to establish VNet peering and route configuration.
module hubNetwork 'modules/hub-network.bicep' = {
  name: 'deploy-hub-network-${deploymentTimestamp}'
  scope: rgNetworking  // All network resources share the networking RG
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // Hub network sends NSG flow logs and firewall diagnostics to this workspace.
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Application Security Groups ─────────────────────────────────────
// AZ-104: ASGs are logical workload tags applied to NICs that NSG rules
// reference instead of subnet CIDRs. Deployed before spokeNetwork so the
// spoke NSG rules can reference ASG IDs in their source/destination fields.
// ASGs are FREE — pure ARM-only constructs with no compute/storage backing.
module asgs 'modules/asgs.bicep' = {
  name: 'deploy-asgs-${deploymentTimestamp}'
  scope: rgNetworking  // Co-located with NSGs and other network primitives.
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
  }
}

// ── Module: Spoke Networks ──────────────────────────────────────────────────
// AZ-104: Spoke VNets host workload subnets (web tier, app tier, data tier).
// They are peered to the hub so that all egress traffic routes through the
// hub Azure Firewall (forced tunneling via UDR with 0.0.0.0/0 next-hop =
// Firewall private IP). Spoke depends on hubNetwork so it receives the hub
// VNet ID (required for peering) and the Firewall private IP (required to
// set the default route in the spoke UDR).
module spokeNetwork 'modules/spoke-network.bicep' = {
  name: 'deploy-spoke-network-${deploymentTimestamp}'
  scope: rgNetworking
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // hubVnetId is used by ARM to create the VNet peering resource on both
    // the hub side and the spoke side (bidirectional peering is required).
    hubVnetId: hubNetwork.outputs.hubVnetId
    // hubVnetName is used to name the peering resource on the hub side.
    hubVnetName: hubNetwork.outputs.hubVnetName
    // The Firewall private IP is injected into the spoke UDR as the
    // next-hop for 0.0.0.0/0, enforcing centralized egress inspection.
    firewallPrivateIp: hubNetwork.outputs.firewallPrivateIp
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    // ASG IDs from the asgs module — referenced in NSG rules via
    // sourceApplicationSecurityGroups / destinationApplicationSecurityGroups
    // arrays for modern micro-segmentation patterns.
    asgWebId: asgs.outputs.asgWebId
    asgAppId: asgs.outputs.asgAppId
    asgMgmtId: asgs.outputs.asgMgmtId
  }
}

// ── Module: Private Endpoints ───────────────────────────────────────────────
// AZ-104: Deploys Private Endpoints for Storage Account (blob subresource)
// and Key Vault (vault subresource), plus the corresponding Private DNS zones
// (privatelink.blob.core.windows.net, privatelink.vaultcore.azure.net) with
// VNet links to the hub and both spokes. After this module deploys, the
// storage account's and Key Vault's publicNetworkAccess can be set to
// Disabled and in-VNet workloads still resolve them to private IPs.
//
// Cost: ~$14/mo total ($7 per PE) plus negligible per-GB processing.
//
// Depends on storage and keyvault modules (for resource IDs) and on
// spokeNetwork (for the snet-pe subnet that hosts the PE NICs).
module privateEndpoints 'modules/private-endpoints.bicep' = {
  name: 'deploy-private-endpoints-${deploymentTimestamp}'
  // Co-locate with the networking RG so PE resources sit alongside other
  // networking primitives (NSGs, VNets, route tables, peering).
  scope: rgNetworking
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // Dedicated subnet for PE NICs — has privateEndpointNetworkPolicies
    // disabled so PE deployment can bind without policy interference.
    peSubnetId: spokeNetwork.outputs.peSubnetId
    // PaaS resource targets — PEs bind to specific subresources of these.
    storageAccountId: storage.outputs.storageAccountId
    keyVaultId: keyvault.outputs.keyVaultId
    // VNet IDs for Private DNS zone vnet links — required so each VNet
    // resolves the PE FQDNs to private IPs instead of public.
    hubVnetId: hubNetwork.outputs.hubVnetId
    webVnetId: spokeNetwork.outputs.webVnetId
    appVnetId: spokeNetwork.outputs.appVnetId
  }
}

// ── Module: VPN Gateway (DISABLED for free trial) ───────────────────────────
// AZ-104: Deploys a Basic-SKU Point-to-Site VPN Gateway in the hub VNet's
// pre-existing GatewaySubnet. Demonstrates hybrid connectivity — individual
// clients can connect over SSTP and access in-VNet resources without exposing
// public IPs. Basic SKU is the cheapest path; production uses VpnGw1+ SKUs
// that support OpenVPN/IKEv2 and BGP.
//
// Cost: ~$27/mo. Provisioning takes 30-45 minutes — the longest-deploying
// resource in the project.
//
// COMMENTED OUT: Free trial subscriptions cap at 3 Public IPs in the region,
// and this module adds a 3rd PIP (`ent-pip-vpngw-prod`) on top of the existing
// Bastion + LB PIPs, exceeding the quota. To enable in production:
//   1. Request Public IP quota increase via the Azure portal, OR
//   2. Upgrade subscription to Pay-As-You-Go (gets standard quota), OR
//   3. Deploy the VPN Gateway separately via PORTAL-DEPLOYMENT-GUIDE.md → Step 9.6
//      (single resource won't trigger orchestrator-level quota validation).
//
// module vpnGateway 'modules/vpn-gateway.bicep' = {
//   name: 'deploy-vpn-gateway-${deploymentTimestamp}'
//   scope: rgNetworking
//   params: {
//     location: location
//     environment: environment
//     orgPrefix: orgPrefix
//     tags: globalTags
//     hubVnetId: hubNetwork.outputs.hubVnetId
//   }
// }

// ── Module: Load Balancers ──────────────────────────────────────────────────
// AZ-104: Deploys Azure Load Balancers for both the web tier (public-facing,
// Standard SKU with a public IP) and the app tier (internal, distributing
// traffic from the web tier to app-tier VMSS instances). Load balancers must
// be deployed before VMSS so that backend pool IDs are available to attach
// VMSS NICs to. The module depends on spokeNetwork for subnet IDs which
// define the frontend IP configuration placement.
module loadBalancers 'modules/load-balancers.bicep' = {
  name: 'deploy-load-balancers-${deploymentTimestamp}'
  scope: rgNetworking  // LBs are network resources; placed in networking RG
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // Subnet IDs determine where the LB frontend IPs are homed.
    // webSubnetId → public LB frontend; appSubnetId → internal LB frontend.
    webSubnetId: spokeNetwork.outputs.webSubnetId
    appSubnetId: spokeNetwork.outputs.appSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Compute (VMSS) — DISABLED for free trial ────────────────────────
// AZ-104: Deploys Virtual Machine Scale Sets for the web and app tiers.
// VMSS provides horizontal scaling (auto-scale rules based on CPU/memory),
// rolling upgrades, and integration with Azure Load Balancer backend pools.
//
// COMMENTED OUT: Free trial subscriptions have a 4-core regional quota in
// eastus2, but the web + app VMSS together require 12 cores (Standard_B2s ×
// 2 instances × 2 scale sets × 2 vCPU/instance + extras). To enable:
//   1. Request 'Total Regional vCPUs' quota increase to 12+ in Azure portal
//      (Subscriptions → Usage + quotas → Request increase), OR
//   2. Upgrade subscription to Pay-As-You-Go (gets 20-core default quota), OR
//   3. Deploy compute manually via the portal one VM at a time to fit quota.
//
// module compute 'modules/compute.bicep' = {
//   name: 'deploy-compute-${deploymentTimestamp}'
//   scope: rgCompute
//   params: {
//     location: location
//     environment: environment
//     orgPrefix: orgPrefix
//     tags: globalTags
//     webSubnetId: spokeNetwork.outputs.webSubnetId
//     appSubnetId: spokeNetwork.outputs.appSubnetId
//     webLbBackendPoolId: loadBalancers.outputs.webLbBackendPoolId
//     appLbBackendPoolId: loadBalancers.outputs.appLbBackendPoolId
//     logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
//     keyVaultName: keyvault.outputs.keyVaultName
//     keyVaultResourceGroup: rgSecurity.name
//     adminPassword: adminPassword
//   }
// }

// ── Module: Backup (Recovery Services) ──────────────────────────────────────
// AZ-104: Deploys a Recovery Services Vault and backup policies for VMs.
// Azure Backup provides RPO/RTO guarantees for VM workloads. The vault is
// scoped to rgCompute because it directly manages backup items for VMs in
// that resource group. Diagnostic settings on the vault emit backup job
// status to Log Analytics for alerting on backup failures.
module backup 'modules/backup.bicep' = {
  name: 'deploy-backup-${deploymentTimestamp}'
  scope: rgCompute  // Recovery Services Vault co-located with protected VMs
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: DNS ─────────────────────────────────────────────────────────────
// AZ-104: Deploys an Azure Public DNS zone for the organization's domain
// and creates A/CNAME records pointing to the web load balancer public IP.
// Azure DNS zones are global resources (not regional) so no location param
// is required. The webLbPublicIpId output from loadBalancers is used to
// create an alias (A) record that automatically follows IP changes when
// the LB public IP is updated.
module dns 'modules/dns.bicep' = {
  name: 'deploy-dns-${deploymentTimestamp}'
  scope: rgNetworking  // DNS zones are logically part of the network layer
  params: {
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // The public IP resource ID of the web load balancer; DNS creates an
    // alias A record pointing the public zone apex to this IP.
    webLbPublicIpId: loadBalancers.outputs.webLbPublicIpId
  }
}

// ── Module: App Service ─────────────────────────────────────────────────────
// AZ-104: Deploys an Azure App Service Plan and Web App as an alternative
// PaaS compute option alongside the VMSS. VNet Integration (via appSubnetId)
// connects the App Service to the spoke network so it can reach the app tier
// over private IPs rather than traversing the public internet. Diagnostic
// logs (HTTP logs, application logs) route to Log Analytics.
// COMMENTED OUT: App Service Plan + Web App. Free trial subscriptions can
// often only deploy F1 (Free) tier; this module uses B1+ which may hit the
// regional App Service plan quota. Re-enable after upgrading subscription.
//
// module appService 'modules/app-service.bicep' = {
//   name: 'deploy-appservice-${deploymentTimestamp}'
//   scope: rgCompute
//   params: {
//     location: location
//     environment: environment
//     orgPrefix: orgPrefix
//     tags: globalTags
//     logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
//     appSubnetId: spokeNetwork.outputs.appSubnetId
//   }
// }

// ── Module: Containers (ACI + ACR) — DISABLED for free trial ────────────────
// COMMENTED OUT: ACR Basic + ACI deploy fine on free trial cost-wise (~$5/mo
// + per-second), but this module pre-creates a network-injected ACI that
// requires container creation succeeding before downstream resources resolve.
// Re-enable once compute/VMSS are also deployed.
//
// module containers 'modules/containers.bicep' = {
//   name: 'deploy-containers-${deploymentTimestamp}'
//   scope: rgCompute
//   params: {
//     location: location
//     environment: environment
//     orgPrefix: orgPrefix
//     tags: globalTags
//     appSubnetId: spokeNetwork.outputs.appSubnetId
//     logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
//   }
// }

// ── Module: Disks & Snapshots — DISABLED for free trial ────────────────────
// COMMENTED OUT: Standalone managed disks + snapshots cost ~$15/mo for the
// 128 GB Premium SSD allocated. Re-enable when running the full enterprise
// deploy with VMSS and App Service.
//
// module disks 'modules/disks.bicep' = {
//   name: 'deploy-disks-${deploymentTimestamp}'
//   scope: rgCompute
//   params: {
//     location: location
//     environment: environment
//     orgPrefix: orgPrefix
//     tags: globalTags
//   }
// }

// ── Module: Governance ──────────────────────────────────────────────────────
// AZ-104: Deploys Azure Policy assignments and resource locks at the
// subscription or resource group scope. Governance is intentionally deployed
// without a scope override (defaults to subscription) so that policies can
// apply across all resource groups created in this deployment. The array of
// resource group names is passed so the module can create CanNotDelete locks
// on production RGs. Azure Policy enforces compliance automatically (e.g.,
// "allowed locations", "require tags", "allowed VM SKUs").
module governance 'modules/governance.bicep' = {
  name: 'deploy-governance-${deploymentTimestamp}'
  // No scope = subscription scope (matches targetScope at top of file).
  // Policy assignments at subscription scope apply to all child RGs.
  params: {
    environment: environment
    // All five resource group names are passed so governance can apply
    // resource locks and tag compliance policies to each one individually.
    resourceGroupNames: [
      rgNetworking.name
      rgCompute.name
      rgStorage.name
      rgSecurity.name
      rgMonitoring.name
    ]
  }
  // Wait for monitoring + storage + keyvault + backup writes to finish before
  // creating resource locks. Otherwise the ReadOnly lock on the monitoring RG
  // is applied first and blocks the workbook + VMInsights solution writes
  // with ScopeLocked errors. Same pattern protects the security and
  // networking RGs from race conditions on subsequent module updates.
  dependsOn: [
    monitoring
    storage
    keyvault
    backup
    privateEndpoints
    spokeNetwork
    hubNetwork
    loadBalancers
    asgs
  ]
}

// ── Module: Identity (RBAC) ─────────────────────────────────────────────────
// AZ-104: Deploys Azure RBAC role assignments at the resource group scope.
// Role assignments bind a security principal (user, group, or managed
// identity) to a role definition (built-in or custom) at a specific scope.
// This module uses the resource group IDs (not names) as scope values for
// role assignment resources. Deployed at subscription scope so it can create
// role assignments on multiple resource groups in one pass.
module identity 'modules/identity.bicep' = {
  name: 'deploy-identity-${deploymentTimestamp}'
  // No scope = subscription scope; role assignments target individual RG IDs.
  params: {
    environment: environment
    // Resource group IDs (full ARM paths) are used as the scope property
    // on roleAssignment resources inside the module.
    computeResourceGroupId: rgCompute.id
    networkingResourceGroupId: rgNetworking.id
    monitoringResourceGroupId: rgMonitoring.id
  }
}

// ── Module: Entra Identity (Managed Identities) ─────────────────────────────
// AZ-104: Deploys user-assigned managed identities at the subscription scope.
// Managed identities eliminate the need for credential management — Azure
// automatically provisions and rotates the underlying service principal
// credentials. User-assigned managed identities are created independently
// and can be attached to multiple resources (e.g., shared identity for all
// VMSS instances in an environment). Deployed at subscription scope because
// managed identity resources can be referenced across resource groups.
module entraIdentity 'modules/entra-identity.bicep' = {
  name: 'deploy-entra-identity-${deploymentTimestamp}'
  // Managed identities are RG-scoped resources; deploy into the security RG
  // so they sit alongside Key Vault and other identity infrastructure.
  scope: rgSecurity
  params: {
    environment: environment
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
// AZ-104: Outputs surface key resource identifiers and addresses after a
// successful deployment. They are accessible via:
//   az deployment sub show --name <name> --query "properties.outputs"
// This script also uses them in deploy.ps1 to print a post-deployment
// summary. Outputs should not expose secrets — use Key Vault references
// in consuming scripts instead of outputting sensitive values.

// resourceGroups: Returns the full map of resource group names so automation
// scripts (teardown, CI/CD) can reference them without hard-coding names.
output resourceGroups object = resourceGroupNames

// hubVnetId: The full ARM resource ID of the hub VNet. Used by external
// modules or peering configurations that need to reference the hub.
output hubVnetId string = hubNetwork.outputs.hubVnetId

// bastionPublicIp: The public IP address of Azure Bastion in the hub.
// Administrators connect to VMs through Bastion over HTTPS (port 443)
// — there is no need to expose SSH/RDP ports on VM NICs.
output bastionPublicIp string = hubNetwork.outputs.bastionPublicIp

// webLbPublicIp: The public IP of the web-tier load balancer. Used for
// DNS A record creation and for smoke-testing the deployment.
output webLbPublicIp string = loadBalancers.outputs.webLbPublicIp

// logAnalyticsWorkspaceId: The full resource ID of the Log Analytics
// workspace. Used by external scripts that need to query logs or create
// additional diagnostic settings post-deployment.
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId

// keyVaultUri: The HTTPS URI of the Key Vault (e.g., https://ent-kv-prod.vault.azure.net/).
// Applications and automation scripts use this URI with managed identity
// authentication to retrieve secrets at runtime.
output keyVaultUri string = keyvault.outputs.keyVaultUri

// storageAccountName: The name of the primary storage account. Needed by
// storage-operations.ps1 to generate SAS tokens and perform key rotation.
output storageAccountName string = storage.outputs.storageAccountName

// recoveryVaultName: The name of the Recovery Services Vault. Used by
// backup management scripts to trigger on-demand backups or check policy
// compliance.
output recoveryVaultName string = backup.outputs.vaultName

// webAppHostname / acrLoginServer outputs commented out — the appService
// and containers modules are disabled for the free trial deploy. Re-enable
// after upgrading subscription quotas.
// output webAppHostname string = appService.outputs.webAppDefaultHostname
// output acrLoginServer string = containers.outputs.acrLoginServer

// dnsNameServers: The authoritative name server array for the public DNS
// zone. After deployment, these NS records must be set at your domain
// registrar to delegate the zone to Azure DNS.
output dnsNameServers array = dns.outputs.publicDnsNameServers
