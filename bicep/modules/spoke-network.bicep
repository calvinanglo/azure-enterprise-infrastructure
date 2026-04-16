// ============================================================================
// Spoke Networks — Web + App tiers with NSGs, UDRs, peering back to hub
// ============================================================================
// AZ-104 Context: In a hub-and-spoke topology, spoke VNets isolate workloads
// by tier (web, app, data). Each spoke peers with the central hub VNet so
// shared services (firewall, DNS, Bastion) remain centralised. This module
// provisions two spokes — web-tier and app-tier — and enforces traffic
// inspection via User Defined Routes (UDRs) and Network Security Groups (NSGs).

// ── Parameters ──────────────────────────────────────────────────────────────

// Azure region where all resources in this module will be deployed.
// Passing location as a parameter (rather than hardcoding) makes the module
// reusable across regions without code changes.
param location string

// Deployment environment label (e.g. 'prod', 'dev', 'uat').
// Injected into every resource name and tag to distinguish environments
// sharing the same subscription or resource group.
param environment string

// Short organisation prefix used as the first segment of every resource name
// (e.g. 'contoso'). Keeps names globally unique and easily identifiable in
// the portal without relying on auto-generated suffixes.
param orgPrefix string

// Key-value tag object applied to every resource.
// Tags support cost management, chargeback, and Azure Policy compliance
// checks — all core AZ-104 governance concerns.
param tags object

// Full Azure Resource ID of the hub VNet (e.g. /subscriptions/.../vnet-hub-prod).
// Required on the spoke side of each peering so Azure knows which remote
// network to connect to. The ID is stable and does not change with renames.
param hubVnetId string

// Friendly name of the hub VNet (e.g. 'contoso-vnet-hub-prod').
// Used to construct the hub-side peering child resource name, which follows
// the pattern '<parentVnetName>/<peeringName>' for the unparented syntax.
param hubVnetName string

// Private IP address of the Azure Firewall deployed in the hub VNet.
// This is the next-hop address for all UDR routes — all spoke traffic is
// steered to this IP for centralised inspection before being forwarded.
param firewallPrivateIp string

// Resource ID of the Log Analytics Workspace used for centralised logging.
// Diagnostic settings on each NSG reference this workspace so flow logs and
// security events are aggregated in one place for SIEM/monitoring purposes.
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

// Constructed VNet names following the CAF naming convention:
// <orgPrefix>-vnet-<tier>-<environment>
// Centralising name construction in variables avoids repetition and ensures
// consistent naming across all child resources that reference these VNets.
var webSpokeName = '${orgPrefix}-vnet-web-${environment}'
var appSpokeName = '${orgPrefix}-vnet-app-${environment}'

// Non-overlapping RFC 1918 address spaces for each spoke.
// 10.1.0.0/16 = web spoke  (65 534 usable host addresses)
// 10.2.0.0/16 = app spoke  (65 534 usable host addresses)
// These must not overlap with the hub (typically 10.0.0.0/16) or with each
// other, otherwise VNet peering and routing will fail with address conflicts.
var webAddressSpace = '10.1.0.0/16'
var appAddressSpace = '10.2.0.0/16'

// /24 subnet prefixes carved from each spoke's address space.
// A /24 provides 251 usable IPs after Azure reserves 5 addresses per subnet.
// Keeping subnet prefixes in variables allows the NSG app-tier rule to
// reference webSubnetPrefix directly, ensuring the source filter stays in
// sync if the prefix ever changes.
var webSubnetPrefix = '10.1.1.0/24'
var appSubnetPrefix = '10.2.1.0/24'

// ── Route Table (force traffic through firewall) ───────────────────────────
// AZ-104 Context: User Defined Routes (UDRs) override Azure's default system
// routes. By associating this route table with spoke subnets, ALL egress
// traffic — including spoke-to-spoke — is redirected to the Azure Firewall
// instead of flowing directly via peering. This is the foundation of a
// hub-and-spoke security model: centralised, auditable traffic inspection.

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  // Name follows CAF convention; scoped to org + environment for multi-env deployments.
  name: '${orgPrefix}-rt-spoke-to-fw-${environment}'
  // Resources must be in the same region as the VNets they are associated with.
  location: location
  // Tags ensure cost attribution and compliance policy alignment.
  tags: tags
  properties: {
    // Disable BGP route propagation to prevent on-premises routes learned via
    // ExpressRoute or VPN Gateway from being injected into spoke subnets.
    // If BGP routes were allowed, traffic could bypass the firewall by taking
    // a learned route instead of the explicit UDR below.
    disableBgpRoutePropagation: true
    routes: [
      {
        // Default route: intercepts ALL internet-bound and unknown-destination
        // traffic and forces it through the Azure Firewall for inspection/filtering.
        name: 'route-to-firewall'
        properties: {
          // 0.0.0.0/0 is the default route — it matches every destination not
          // covered by a more specific route entry, effectively catching all
          // internet egress and unresolved destinations.
          addressPrefix: '0.0.0.0/0'
          // VirtualAppliance tells Azure to forward packets to a specific IP
          // (the firewall) rather than using the default internet gateway or
          // VNet peering path.
          nextHopType: 'VirtualAppliance'
          // The Azure Firewall's private IP in the hub VNet AzureFirewallSubnet.
          // Traffic arriving here is inspected against firewall policy rules
          // before being allowed or denied.
          nextHopIpAddress: firewallPrivateIp
        }
      }
      {
        // Spoke-to-spoke route: catches all RFC 1918 10.x.x.x traffic so that
        // lateral movement between spokes is also routed through the firewall,
        // not directly through VNet peering paths. Without this route, a VM in
        // the web spoke could reach the app spoke without any firewall inspection.
        name: 'route-spoke-to-spoke'
        properties: {
          // 10.0.0.0/8 covers the entire private 10.x range, encompassing both
          // spoke address spaces (10.1.0.0/16, 10.2.0.0/16) and the hub
          // (10.0.0.0/16). More specific routes always win over this summary.
          addressPrefix: '10.0.0.0/8'
          // Again route to the firewall so east-west traffic is inspected.
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// ── Web Tier NSG ───────────────────────────────────────────────────────────
// AZ-104 Context: Network Security Groups are stateful Layer-4 firewalls
// applied at the subnet or NIC level. Rules are evaluated in priority order
// (lower number = higher priority) and processing stops at the first match.
// The web NSG permits only public HTTP/S and Bastion management traffic,
// enforcing least-privilege access to the internet-facing tier.

resource webNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  // NSG name follows CAF convention scoped by tier and environment.
  name: '${orgPrefix}-nsg-web-${environment}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Permit public HTTP traffic to web-tier VMs / load balancer frontend.
        // Port 80 is required for plain-text access and HTTP→HTTPS redirects.
        name: 'Allow-HTTP-Inbound'
        properties: {
          // Priority 100 — evaluated first, well below the 4096 deny-all.
          // Lower priorities (100-199) are reserved for critical allow rules.
          priority: 100
          direction: 'Inbound'  // Applies to traffic arriving at the subnet.
          access: 'Allow'
          protocol: 'Tcp'       // HTTP only runs over TCP.
          // 'Internet' is an Azure service tag representing all public IP ranges
          // not belonging to Azure datacentres — avoids maintaining an IP list.
          sourceAddressPrefix: 'Internet'
          // Source port is ephemeral and unpredictable; wildcard is correct here.
          sourcePortRange: '*'
          // '*' = any IP within the subnet — the NSG is already subnet-scoped.
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        // Permit public HTTPS traffic. Encrypted web traffic is the production
        // standard; this rule is required alongside port 80 for full web access.
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 110  // One slot after HTTP; both are high-priority allows.
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        // Allow Azure Load Balancer health probes to reach backend VMs.
        // If this rule is missing, health probes fail, the LB marks all
        // instances as unhealthy, and traffic stops flowing even if VMs are up.
        // 'AzureLoadBalancer' is an Azure service tag resolving to 168.63.129.16,
        // the magic IP Azure uses for all internal platform communications.
        name: 'Allow-LB-Probes'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'  // Azure service tag — platform probe IP.
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          // Wildcard port because probe port is configured on the LB rule,
          // not fixed in the NSG — keeps the NSG decoupled from LB config.
          destinationPortRange: '*'
        }
      }
      {
        // Allow Azure Bastion to reach web-tier VMs for SSH (22) and RDP (3389).
        // Bastion is deployed in the hub VNet's AzureBastionSubnet (10.0.2.0/26).
        // Restricting the source to that specific /26 prevents any other host
        // in the 10.x range from attempting SSH/RDP directly, enforcing the
        // Bastion-only management access pattern required in secure environments.
        name: 'Allow-Bastion-SSH-RDP'
        properties: {
          priority: 200  // Lower priority than web rules; management is secondary.
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          // Explicit CIDR of the hub's AzureBastionSubnet — more restrictive
          // than using a service tag, tying access to this specific subnet.
          sourceAddressPrefix: '10.0.2.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          // Both SSH (Linux) and RDP (Windows) management ports are permitted
          // so the NSG supports mixed OS environments in the web tier.
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        // Explicit deny-all catch-all rule at the maximum NSG priority.
        // Azure has an implicit deny-all at priority 65500, but this explicit
        // rule at 4096 is documented and auditable — it makes the security
        // posture transparent and satisfies compliance requirements that demand
        // visible deny rules rather than relying on implicit platform behaviour.
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096  // Highest number = lowest priority; evaluated last.
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'              // Match all protocols.
          sourceAddressPrefix: '*'   // Match any source.
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'  // Match any destination port.
        }
      }
    ]
  }
}

// ── App Tier NSG ───────────────────────────────────────────────────────────
// AZ-104 Context: The app tier NSG implements a defence-in-depth layer for
// the middle tier. Unlike the web NSG it does NOT allow inbound traffic from
// the Internet — only from the web subnet and the load balancer. This enforces
// a strict N-tier architecture where the app tier is never directly exposed
// to public traffic, reducing the blast radius of a web-tier compromise.

resource appNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-nsg-app-${environment}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Permit the web tier to call the app tier on its application ports.
        // Locking the source to webSubnetPrefix (10.1.1.0/24) ensures that
        // only web-tier VMs — not arbitrary hosts — can reach the app tier,
        // implementing micro-segmentation between spoke subnets.
        name: 'Allow-From-Web-Tier'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          // Source is the web subnet CIDR variable — if the prefix changes,
          // this rule stays correct automatically without a separate update.
          sourceAddressPrefix: webSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          // 8080 = HTTP alternative port commonly used by app servers (Tomcat,
          // Node.js, etc.). 8443 = HTTPS alternative, used when TLS termination
          // happens at the app tier rather than the web tier or load balancer.
          destinationPortRanges: ['8080', '8443']
        }
      }
      {
        // Same rationale as the web-tier LB probe rule: the internal load
        // balancer fronting app-tier VMs must be able to run health probes or
        // it will not route traffic to healthy backend instances.
        name: 'Allow-LB-Probes'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        // Same Bastion management rule as the web NSG — Bastion in the hub
        // must be able to reach app-tier VMs for administrative access.
        // Source is the same AzureBastionSubnet CIDR (10.0.2.0/26) so access
        // is still limited to the centralised jump-host path only.
        name: 'Allow-Bastion-SSH-RDP'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.2.0/26'  // Hub AzureBastionSubnet CIDR.
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        // Explicit deny-all for the app tier — mirrors the web NSG deny rule.
        // Any traffic not matched by the three allow rules above is dropped,
        // including any attempt to reach the app tier from the Internet or
        // from other spokes that are not the web subnet.
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── NSG Diagnostics ────────────────────────────────────────────────────────
// AZ-104 Context: Diagnostic settings stream NSG flow logs and event logs to
// a Log Analytics Workspace for centralised monitoring. This satisfies Azure
// Security Benchmark controls and enables Defender for Cloud, Sentinel, and
// custom KQL queries to detect anomalous traffic patterns across both tiers.

// Diagnostic settings for the web-tier NSG.
resource webNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  // Convention name used consistently across all NSG diagnostic resources.
  name: 'send-to-law'
  // 'scope' attaches this diagnostic setting to the web NSG specifically,
  // not to the resource group or subscription — each NSG needs its own setting.
  scope: webNsg
  properties: {
    // Destination workspace where logs will be ingested and retained.
    // Using a shared workspace (passed as a parameter from the hub module)
    // keeps all spoke telemetry in one place for cross-tier correlation.
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      // 'allLogs' is a category group that enables every log category the
      // resource type supports (NetworkSecurityGroupEvent,
      // NetworkSecurityGroupRuleCounter) without listing each one explicitly.
      // Setting enabled: true activates streaming immediately on deployment.
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

// Diagnostic settings for the app-tier NSG — identical configuration to the
// web NSG diagnostic resource but scoped to appNsg. Each NSG requires its own
// diagnostic setting; a single setting cannot cover multiple resources.
resource appNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  // Scope binds this setting to the app NSG only.
  scope: appNsg
  properties: {
    // Same shared Log Analytics Workspace as the web tier so both NSGs'
    // logs land in the same workspace for unified querying and alerting.
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

// ── Web Spoke VNet ─────────────────────────────────────────────────────────
// AZ-104 Context: The web spoke VNet provides network isolation for the
// internet-facing tier. By housing web VMs in their own VNet (rather than
// a subnet of the hub), the blast radius of a compromise is limited: an
// attacker cannot reach other spokes without traversing the hub firewall.

resource webVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  // Name built from the variable defined above for consistent CAF naming.
  name: webSpokeName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      // Single address space block for the web spoke.
      // Must not overlap with hub (10.0.0.0/16) or app spoke (10.2.0.0/16);
      // overlapping address spaces prevent VNet peering from being created.
      addressPrefixes: [webAddressSpace]  // 10.1.0.0/16
    }
    subnets: [
      {
        // 'snet-web' is the single subnet in this spoke; additional subnets
        // (e.g. for a dedicated DB tier or private endpoints) can be added here
        // while reusing the same VNet and peering configuration.
        name: 'snet-web'
        properties: {
          // Assigns the /24 prefix carved from the spoke's /16 address space.
          // Defining it inline in the VNet resource avoids a separate subnet
          // resource and prevents the known Bicep ordering issue where subnet
          // resources and NSG associations can conflict on updates.
          addressPrefix: webSubnetPrefix  // 10.1.1.0/24
          // Associates the web NSG with this subnet, applying all inbound/
          // outbound rules defined above to every NIC in the subnet.
          networkSecurityGroup: { id: webNsg.id }
          // Associates the UDR route table, redirecting all egress traffic
          // (internet and cross-spoke) to the Azure Firewall in the hub.
          routeTable: { id: routeTable.id }
        }
      }
    ]
  }
}

// ── App Spoke VNet ─────────────────────────────────────────────────────────
// AZ-104 Context: Mirrors the web spoke structure but for the app (middle)
// tier. Isolation in its own VNet means that even if the web subnet is
// compromised, the attacker cannot reach the app subnet without a deliberate
// firewall rule permitting that path — enforcing defence in depth.

resource appVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: appSpokeName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      // 10.2.0.0/16 — separate, non-overlapping space for the app spoke.
      // VNet peering requires unique address spaces across all peered VNets.
      addressPrefixes: [appAddressSpace]  // 10.2.0.0/16
    }
    subnets: [
      {
        // Single app-tier subnet; follow the same inline-definition pattern
        // used for the web spoke to avoid Bicep NSG association race conditions.
        name: 'snet-app'
        properties: {
          addressPrefix: appSubnetPrefix  // 10.2.1.0/24
          // App NSG restricts inbound to web-tier source and Bastion only —
          // the app subnet is not directly reachable from the internet.
          networkSecurityGroup: { id: appNsg.id }
          // Same shared route table as the web spoke: all egress goes through
          // the firewall, including app-to-database and app-to-internet traffic.
          routeTable: { id: routeTable.id }
        }
      }
    ]
  }
}

// ── VNet Peering: Hub ↔ Web Spoke ──────────────────────────────────────────
// AZ-104 Context: VNet peering is non-transitive by default — two spokes
// cannot communicate through the hub unless explicitly routed. Peering must
// be created in BOTH directions (hub→spoke and spoke→hub) to establish a
// fully functional bidirectional link. Each peering is a separate ARM resource.

// Hub-side peering: creates the peering object inside the hub VNet.
// This uses the unparented child-resource syntax (name includes parent VNet
// name) because the hub VNet is deployed in a different module/scope.
resource hubToWebPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  // Format: '<parentVnetName>/<peeringName>' — required when the parent VNet
  // is not declared as a resource in this Bicep file.
  name: '${hubVnetName}/peer-hub-to-web'
  properties: {
    // Points to the web spoke VNet being peered with the hub.
    remoteVirtualNetwork: { id: webVnet.id }
    // Allow traffic to flow between the hub and the web spoke VMs.
    // Setting this to false would block all peered traffic — only metadata
    // about the peered VNet would be exchanged.
    allowVirtualNetworkAccess: true
    // Allow the hub to forward traffic that originated outside the hub VNet
    // (e.g. from on-premises via VPN/ExpressRoute) into the web spoke.
    // Required for the hub-and-spoke model where the hub acts as a transit hub.
    allowForwardedTraffic: true
    // Allow the hub's VPN/ExpressRoute Gateway to be used by the web spoke.
    // With gateway transit enabled on the hub side, spokes can leverage the
    // hub's gateway for on-premises connectivity without deploying their own.
    allowGatewayTransit: true
    // The hub does not use a remote gateway — it IS the gateway owner.
    // Setting this to false on the hub side prevents a configuration conflict.
    useRemoteGateways: false
  }
}

// Spoke-side peering: creates the peering object inside the web spoke VNet.
// Uses the 'parent' keyword because webVnet IS declared in this same file.
resource webToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  // 'parent' sets webVnet as the containing resource, equivalent to prefixing
  // the name with '${webVnet.name}/' but cleaner and less error-prone.
  parent: webVnet
  name: 'peer-web-to-hub'
  properties: {
    // Points back to the hub VNet using the resource ID passed as a parameter.
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    // Allow the hub firewall's forwarded traffic (from other spokes or
    // on-premises) to enter the web spoke — needed for spoke-to-spoke routing
    // via the firewall UDR path.
    allowForwardedTraffic: true
    // The spoke does not own a gateway, so gateway transit is irrelevant here.
    // Must be false when useRemoteGateways is also false (cannot transit a
    // gateway that you are not using).
    allowGatewayTransit: false
    // Set to false because the hub does not have a VPN/ExpressRoute Gateway
    // in this deployment. If a gateway were present and allowGatewayTransit
    // were true on the hub side, this would be set to true to enable spoke
    // on-premises connectivity via the hub gateway.
    useRemoteGateways: false
  }
}

// ── VNet Peering: Hub ↔ App Spoke ──────────────────────────────────────────
// AZ-104 Context: Identical peering pattern to hub↔web but for the app spoke.
// Both directions must be created independently — Azure does not automatically
// create the return peering when you create one side.

// Hub-side peering for the app spoke — same rationale as hubToWebPeering above.
resource hubToAppPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: '${hubVnetName}/peer-hub-to-app'
  properties: {
    remoteVirtualNetwork: { id: appVnet.id }
    allowVirtualNetworkAccess: true
    // Hub must forward traffic to the app spoke from other sources (other
    // spokes, on-premises) — same forwarding requirement as the web peering.
    allowForwardedTraffic: true
    // Hub side enables gateway transit so the app spoke can optionally use
    // the hub gateway for on-premises access if useRemoteGateways is enabled
    // on the spoke side in future.
    allowGatewayTransit: true
    useRemoteGateways: false  // Hub is the gateway owner, not a consumer.
  }
}

// App spoke-side peering back to the hub — mirrors webToHubPeering in
// structure; the parent keyword scopes the resource under appVnet.
resource appToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: appVnet  // Scopes this peering as a child of the app spoke VNet.
  name: 'peer-app-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    // Forwarded traffic must be allowed so the firewall in the hub can pass
    // packets between spokes (e.g. web→firewall→app) after UDR inspection.
    allowForwardedTraffic: true
    allowGatewayTransit: false   // Spoke does not own a gateway to transit.
    useRemoteGateways: false     // No hub gateway deployed; match hub config.
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// AZ-104 Context: Outputs expose resource identifiers to the parent/caller
// Bicep template so downstream modules (VM deployments, private endpoints,
// load balancers) can reference these VNets and subnets by ID without
// hard-coding values or requiring manual lookups in the portal.

// Full resource ID of the web spoke VNet — consumed by modules that deploy
// VMs, NICs, or application gateways into the web tier.
output webVnetId string = webVnet.id

// Full resource ID of the app spoke VNet — consumed by modules deploying
// app-tier VMs, internal load balancers, or private endpoints.
output appVnetId string = appVnet.id

// Full resource ID of the web subnet, constructed by appending the subnet
// name to the VNet ID. Used when creating NICs or referencing subnets in
// load balancer backend pool and private endpoint configurations.
output webSubnetId string = '${webVnet.id}/subnets/snet-web'

// Full resource ID of the app subnet — same construction pattern as above.
// Passed to app-tier NIC and internal load balancer deployments.
output appSubnetId string = '${appVnet.id}/subnets/snet-app'
