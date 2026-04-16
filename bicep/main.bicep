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
  }
}

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

// ── Module: Compute (VMSS) ──────────────────────────────────────────────────
// AZ-104: Deploys Virtual Machine Scale Sets for the web and app tiers.
// VMSS provides horizontal scaling (auto-scale rules based on CPU/memory),
// rolling upgrades, and integration with Azure Load Balancer backend pools.
// The module has the most dependencies — it needs subnet IDs (networking),
// LB backend pool IDs (load-balancers), storage (boot diagnostics), and
// Key Vault (to fetch secrets via managed identity at runtime).
module compute 'modules/compute.bicep' = {
  name: 'deploy-compute-${deploymentTimestamp}'
  scope: rgCompute  // VMs and VMSS land in the compute resource group
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // VMSS NIC configurations reference these subnet IDs to place
    // instances in the correct spoke subnets.
    webSubnetId: spokeNetwork.outputs.webSubnetId
    appSubnetId: spokeNetwork.outputs.appSubnetId
    // Backend pool IDs are needed so VMSS NIC IP configs are registered
    // with the respective load balancer automatically at scale-out.
    webLbBackendPoolId: loadBalancers.outputs.webLbBackendPoolId
    appLbBackendPoolId: loadBalancers.outputs.appLbBackendPoolId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    // VMSS instances use system-assigned managed identity to pull secrets
    // from Key Vault without storing credentials in the VM extension config.
    keyVaultName: keyvault.outputs.keyVaultName
    keyVaultResourceGroup: rgSecurity.name
  }
}

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
module appService 'modules/app-service.bicep' = {
  name: 'deploy-appservice-${deploymentTimestamp}'
  scope: rgCompute  // PaaS compute alongside IaaS in the same compute RG
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    // VNet Integration subnet — the App Service delegates outbound traffic
    // through this subnet to access private resources in the spoke VNet.
    appSubnetId: spokeNetwork.outputs.appSubnetId
  }
}

// ── Module: Containers (ACI + ACR) ──────────────────────────────────────────
// AZ-104: Deploys Azure Container Registry (ACR) for private image storage
// and Azure Container Instances (ACI) for lightweight container workloads.
// ACR stores Docker images; ACI provides on-demand container execution
// without managing underlying VMs. ACI is connected to the spoke VNet via
// the appSubnetId for private network access, avoiding public endpoint
// exposure for internal workloads.
module containers 'modules/containers.bicep' = {
  name: 'deploy-containers-${deploymentTimestamp}'
  scope: rgCompute  // Container workloads co-located with other compute
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
    // ACI is injected into this subnet so container network traffic stays
    // on the private spoke network and routes through the hub Firewall.
    appSubnetId: spokeNetwork.outputs.appSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// ── Module: Disks & Snapshots ───────────────────────────────────────────────
// AZ-104: Deploys standalone managed disks (Premium SSD / Standard SSD)
// and disk snapshots for demonstration of Azure disk management. Managed
// disks are the recommended block storage type for Azure VMs — they provide
// SLA-backed redundancy (LRS/ZRS/GRS) and integrate with Azure Backup.
// Snapshots enable point-in-time capture of a disk's state for recovery or
// test environment cloning.
module disks 'modules/disks.bicep' = {
  name: 'deploy-disks-${deploymentTimestamp}'
  scope: rgCompute  // Disks are compute resources; co-located with VMs
  params: {
    location: location
    environment: environment
    orgPrefix: orgPrefix
    tags: globalTags
  }
}

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
  // No scope = subscription scope; managed identities are subscription-level.
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

// webAppHostname: The default hostname of the App Service web app
// (e.g., ent-app-prod.azurewebsites.net). Used for smoke tests and DNS
// CNAME record creation.
output webAppHostname string = appService.outputs.webAppDefaultHostname

// acrLoginServer: The login server FQDN of the Azure Container Registry
// (e.g., entacrprod.azurecr.io). Used by CI/CD pipelines for docker push
// and by ACI deployments to pull images.
output acrLoginServer string = containers.outputs.acrLoginServer

// dnsNameServers: The authoritative name server array for the public DNS
// zone. After deployment, these NS records must be set at your domain
// registrar to delegate the zone to Azure DNS.
output dnsNameServers array = dns.outputs.publicDnsNameServers
