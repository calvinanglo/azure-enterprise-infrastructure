// ============================================================================
// Hub Network — Central connectivity: Firewall, Bastion, DNS, VPN Gateway
// ============================================================================
// AZ-104: The hub is the control plane of a Hub-and-Spoke topology.
// All shared, security-sensitive, and connectivity resources live here so that
// spoke VNets never bypass inspection or management controls.
// Microsoft recommends this pattern for enterprise landing zones because it
// centralises egress, enforces a single chokepoint for firewall rules, and
// keeps administration of shared services (Bastion, DNS, VPN) in one place.
// ============================================================================

// ── Parameters ────────────────────────────────────────────────────────────────
// Parameters are injected by the parent/orchestrator template at deploy time,
// keeping this module reusable across environments without hard-coding values.

param location string
// location: Azure region for all resources in this module.
// AZ-104: Deploying the hub in the same region as workload spokes minimises
// latency and avoids cross-region data transfer charges on VNet peering traffic.

param environment string
// environment: Lifecycle stage label (e.g. 'dev', 'staging', 'prod').
// Used to drive SKU decisions (Firewall Basic vs Standard) and naming so
// resources can be identified and governed by environment in Azure Policy.

param orgPrefix string
// orgPrefix: Short organisation identifier prepended to every resource name.
// AZ-104: Consistent naming conventions are required for RBAC, cost management,
// and Azure Policy assignments — auditors and administrators can identify
// resource ownership at a glance without opening every blade.

param tags object
// tags: Key-value metadata object applied to every resource.
// AZ-104: Tags are the primary mechanism for cost allocation (Cost Management),
// RBAC scope targeting, and Azure Policy compliance evaluation.
// Inheriting a shared tags object ensures uniform taxonomy across the hub.

param logAnalyticsWorkspaceId string
// logAnalyticsWorkspaceId: Resource ID of the centralised Log Analytics workspace.
// AZ-104: Diagnostic settings on every resource forward logs and metrics here,
// enabling Azure Monitor alerting, KQL queries, and Sentinel SIEM integration
// from a single pane of glass — a requirement for enterprise security posture.

// ── Variables ───────────────────────────────────────────────────────────────
// Variables are computed once at compile time and referenced throughout the
// template. Centralising CIDR blocks and names here avoids magic strings and
// makes future IP plan changes a single-line edit.

var hubVnetName = '${orgPrefix}-vnet-hub-${environment}'
// hubVnetName: Constructs the VNet name from org prefix + environment suffix.
// AZ-104: Naming convention aligns with the Cloud Adoption Framework (CAF)
// resource abbreviations (vnet-) so Azure Policy display-name filters and
// RBAC scope paths are predictable across subscriptions.

var hubAddressSpace = '10.0.0.0/16'
// hubAddressSpace: The /16 supernet reserved exclusively for the hub VNet.
// AZ-104: Address spaces must NOT overlap between peered VNets — a /16 gives
// 65 535 addresses and room for future subnet growth without re-addressing.
// Keeping the hub in the 10.0.0.0/16 block and spokes in 10.1.x / 10.2.x
// avoids peering failures caused by conflicting address spaces.

var subnets = {
  // Subnet definitions are grouped in an object for single-source-of-truth
  // referencing — the same values used to create subnets are reused when
  // building resource IDs and NSG rules, eliminating copy-paste errors.

  firewall: {
    name: 'AzureFirewallSubnet'            // Required name — Azure enforces this exact string; any other name causes deployment failure.
    addressPrefix: '10.0.1.0/26'
    // /26 = 64 addresses. AZ-104: Azure Firewall requires a dedicated subnet
    // named exactly 'AzureFirewallSubnet' with a minimum size of /26.
    // No NSG or UDR may be attached to this subnet — the firewall itself IS
    // the traffic inspection point and manages its own routing internally.
  }
  bastion: {
    name: 'AzureBastionSubnet'             // Required name — must be exactly 'AzureBastionSubnet' or the resource deployment fails.
    addressPrefix: '10.0.2.0/26'
    // /26 = 64 addresses. AZ-104: Azure Bastion requires a minimum /26 subnet
    // named exactly 'AzureBastionSubnet'. No NSG with non-Bastion rules is
    // permitted. Bastion replaces jump-box VMs and eliminates the need to
    // expose RDP/SSH ports (3389/22) directly to the public internet.
  }
  gateway: {
    name: 'GatewaySubnet'                  // Required name — VPN/ExpressRoute gateways will not deploy to any other subnet name.
    addressPrefix: '10.0.3.0/27'
    // /27 = 32 addresses. AZ-104: GatewaySubnet must be named exactly
    // 'GatewaySubnet'. Microsoft recommends /27 or larger to accommodate
    // active-active gateway deployments and future gateway scale units.
    // No NSG should be attached to GatewaySubnet — it can block BGP traffic
    // and break site-to-site or ExpressRoute connectivity.
  }
  management: {
    name: 'snet-management'
    // snet-management: Custom subnet for admin jump-hosts, monitoring agents,
    // and infrastructure tooling that must reach resources across the hub.
    addressPrefix: '10.0.4.0/24'
    // /24 = 256 addresses. AZ-104: A /24 provides headroom for management VMs,
    // Azure Arc connected servers, and any future automation workers without
    // exhausting the subnet. Unlike the three dedicated service subnets above,
    // this subnet does accept an NSG (managementNsg) for inbound traffic control.
  }
}

// ── Hub Virtual Network ────────────────────────────────────────────────────
// The hub VNet is the backbone of the entire topology. Spoke VNets peer to it
// and route traffic through the Azure Firewall for east-west and north-south
// inspection. No workload VMs live directly in the hub — it exists solely as
// a shared-services and connectivity layer.

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  // API version 2023-09-01 supports the latest subnet delegation features and
  // the privateEndpointNetworkPolicies property needed for private endpoints.
  name: hubVnetName       // Computed name from orgPrefix + environment variable.
  location: location      // Must match the region of every peered spoke to avoid cross-region peering costs.
  tags: tags              // Inherits the shared tag object for cost allocation and policy compliance.
  properties: {
    addressSpace: {
      addressPrefixes: [hubAddressSpace]
      // addressPrefixes: The list of CIDR blocks owned by this VNet.
      // AZ-104: A VNet can hold multiple non-overlapping prefixes (e.g. IPv4 +
      // IPv6 dual-stack). Here a single /16 is sufficient. This prefix must not
      // overlap with any spoke VNet or on-premises range connected via VPN/ER.
    }
    subnets: [
      // Subnets are declared inline with the VNet resource so Bicep resolves
      // the correct resource ID before the Firewall and Bastion try to reference
      // them. Declaring subnets separately (as child resources) can cause race
      // conditions and overwrite issues in repeated deployments.

      {
        name: subnets.firewall.name           // 'AzureFirewallSubnet' — reserved platform name.
        properties: {
          addressPrefix: subnets.firewall.addressPrefix   // 10.0.1.0/26 — minimum /26 enforced by ARM.
          // No NSG property here: Azure Firewall manages its own packet
          // filtering; attaching an NSG would double-filter and likely break
          // asymmetric routing for SNAT traffic.
        }
      }
      {
        name: subnets.bastion.name            // 'AzureBastionSubnet' — reserved platform name.
        properties: {
          addressPrefix: subnets.bastion.addressPrefix    // 10.0.2.0/26 — minimum /26 required by Bastion.
          // No NSG: Bastion has built-in security controls. If an NSG is used
          // on AzureBastionSubnet it must follow the exact inbound/outbound
          // rules documented by Microsoft or Bastion will fail health checks.
        }
      }
      {
        name: subnets.gateway.name            // 'GatewaySubnet' — reserved platform name for VPN/ER gateways.
        properties: {
          addressPrefix: subnets.gateway.addressPrefix    // 10.0.3.0/27 — min /27 for active-active gateway.
          // No NSG: Applying an NSG to GatewaySubnet can block BGP (TCP 179)
          // and IKE (UDP 500/4500) traffic, silently breaking VPN tunnels.
        }
      }
      {
        name: subnets.management.name         // 'snet-management' — custom subnet, no platform naming constraint.
        properties: {
          addressPrefix: subnets.management.addressPrefix  // 10.0.4.0/24 — ample space for admin tooling.
          networkSecurityGroup: {
            id: managementNsg.id
            // Attaches the management NSG to this subnet at VNet creation time.
            // AZ-104: Associating an NSG at the subnet level applies rules to
            // ALL NICs in the subnet regardless of VM-level NSGs — it is the
            // correct scope for a subnet-wide default-deny posture.
            // Bicep resolves managementNsg.id at deploy time via an implicit
            // dependsOn, ensuring the NSG exists before the VNet is created.
          }
        }
      }
    ]
  }
}

// ── Management Subnet NSG ──────────────────────────────────────────────────
// Network Security Groups act as a stateful, layer-4 packet filter.
// AZ-104: NSGs are evaluated per-NIC and/or per-subnet. Attaching one at the
// subnet level (done above in hubVnet) applies the rules before traffic even
// reaches a VM's NIC, providing a defence-in-depth chokepoint that cannot be
// accidentally removed by deleting a VM.

resource managementNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-nsg-management-${environment}'   // CAF naming: nsg-<workload>-<env>
  location: location    // NSG must be in the same region as the subnet it protects.
  tags: tags            // Tag inheritance ensures cost and compliance reporting is consistent.
  properties: {
    securityRules: [
      // AZ-104: NSG rules are evaluated in ascending priority order (lower number = evaluated first).
      // The first matching rule wins — subsequent rules are not evaluated.
      // Default rules (65000 AllowVnetInBound, 65001 AllowAzureLoadBalancerInBound,
      // 65500 DenyAllInBound) are always appended by the platform and cannot be deleted.

      {
        name: 'Allow-Bastion-Inbound'
        // Permits Azure Bastion to open SSH/RDP sessions into management VMs.
        // AZ-104: Bastion connects from its own subnet (10.0.2.0/26) to target
        // VMs over the private network — it never exposes RDP/SSH to the internet.
        // Scoping the source to the Bastion subnet CIDR (not VirtualNetwork or *)
        // follows least-privilege: only Bastion agents can initiate these sessions.
        properties: {
          priority: 100
          // priority 100: Lowest priority number = evaluated first for inbound traffic.
          // AZ-104: Leave gaps between rule priorities (100, 200, 300 …) so future
          // rules can be inserted without renumbering existing ones.
          direction: 'Inbound'      // Rule applies to traffic entering the subnet.
          access: 'Allow'           // Permit matching packets to pass through.
          protocol: 'Tcp'
          // protocol Tcp: RDP (3389) and SSH (22) both run over TCP.
          // Specifying TCP is more restrictive than '*' — UDP traffic on those
          // ports (not used for RDP/SSH) is implicitly excluded.
          sourceAddressPrefix: subnets.bastion.addressPrefix
          // sourceAddressPrefix: Locks the allowed source to the Bastion subnet
          // (10.0.2.0/26). Using a specific CIDR instead of 'VirtualNetwork' or
          // 'Internet' prevents any other subnet or on-premises host from
          // reaching management VMs on these privileged ports.
          sourcePortRange: '*'
          // sourcePortRange '*': Source (ephemeral) ports are random and
          // unpredictable — filtering them provides no security benefit.
          destinationAddressPrefix: '*'
          // destinationAddressPrefix '*': Applies to all VMs in the management
          // subnet. Could be narrowed to specific VM IPs for extra segmentation.
          destinationPortRanges: ['22', '3389']
          // Port 22  = SSH  (Linux management)
          // Port 3389 = RDP (Windows management)
          // AZ-104: Only these two ports need to be reachable from Bastion;
          // all other inbound traffic is caught by the Deny-All rule below.
        }
      }
      {
        name: 'Deny-All-Inbound'
        // Explicit catch-all deny. Although Azure adds a default DenyAllInBound
        // rule at priority 65500, defining it explicitly at 4096 documents intent
        // clearly in the portal and makes the security posture auditable without
        // knowing the platform-default rule numbering.
        properties: {
          priority: 4096
          // priority 4096: High number = evaluated last among custom rules,
          // just before the platform default deny at 65500. Any future Allow
          // rules added with lower priority numbers will still be evaluated first.
          direction: 'Inbound'    // Applies only to inbound direction — outbound is unrelated.
          access: 'Deny'          // Drop matching packets; no TCP RST is sent (silent drop).
          protocol: '*'           // Matches TCP, UDP, ICMP, and all other IP protocols.
          sourceAddressPrefix: '*'          // Matches any source address.
          sourcePortRange: '*'              // Matches any source port.
          destinationAddressPrefix: '*'     // Matches any destination address in the subnet.
          destinationPortRange: '*'         // Matches any destination port.
          // AZ-104: This default-deny pattern implements a Zero Trust network
          // posture — traffic is denied unless explicitly permitted by a higher-
          // priority rule. This reduces blast radius if a new service is added to
          // the subnet without a corresponding NSG rule review.
        }
      }
    ]
  }
}

// ── NSG Diagnostic Settings ────────────────────────────────────────────────
// Diagnostic settings are extension resources that stream a resource's
// platform logs and metrics to one or more destinations (Log Analytics,
// Storage Account, Event Hub). AZ-104: Enabling diagnostics on NSGs captures
// NSG flow logs and security event data, which are essential for:
//   - Network Watcher traffic analytics
//   - Security audit and compliance reporting
//   - Incident investigation (source IP, port, allow/deny decisions)

resource managementNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  // name 'send-to-law': Descriptive name indicating the destination.
  // AZ-104: Only one diagnostic setting per destination type per resource is
  // permitted — using a consistent name ('send-to-law') across all resources
  // lets Azure Policy 'deployIfNotExists' remediation tasks idempotently apply
  // and update settings without creating duplicates.
  scope: managementNsg
  // scope: Binds this diagnostic setting to the management NSG resource.
  // Extension resources always require an explicit scope in Bicep when the
  // target is not the deployment scope itself.
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // workspaceId: Resource ID of the central Log Analytics workspace.
    // AZ-104: Centralising logs in one workspace simplifies cross-resource
    // KQL queries, Microsoft Sentinel data connectors, and alert rules.
    // Using a parameter (rather than hard-coding) keeps this module portable
    // across subscriptions that may use different workspace IDs.
    logs: [
      {
        categoryGroup: 'allLogs'
        // categoryGroup 'allLogs': Wildcard that enables every log category
        // currently offered by the resource type, including any new categories
        // Microsoft adds in future API updates — no template change needed.
        // AZ-104: For NSGs the key category is 'NetworkSecurityGroupEvent' and
        // 'NetworkSecurityGroupRuleCounter'; 'allLogs' captures both.
        enabled: true    // Activates log ingestion into the workspace.
      }
    ]
    // Note: metrics are not included here because NSGs do not expose custom
    // metrics — only logs (flow events and rule hit counters) are available.
  }
}

// ── Azure Firewall ─────────────────────────────────────────────────────────
// Azure Firewall is the hub's centralised, stateful network security appliance.
// AZ-104: It provides FQDN filtering, threat intelligence, TLS inspection
// (Premium), and SNAT/DNAT capabilities. Routing spoke VNets through the
// firewall (via UDRs with next-hop = firewall private IP) enforces a single
// egress point for all outbound internet and cross-spoke traffic.
// Using a Firewall Policy (rather than classic rules) decouples rule management
// from the firewall instance and allows policy inheritance across environments.

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  // Public IP required for the firewall's SNAT (outbound internet) function
  // and for DNAT rules that expose internal services to the internet.
  name: '${orgPrefix}-pip-fw-${environment}'    // CAF naming: pip-<service>-<env>
  location: location    // Must match the firewall's region — cross-region PIPs are not supported.
  tags: tags            // Tag for cost attribution — PIP charges appear separately in billing.
  sku: {
    name: 'Standard'
    // Standard SKU is mandatory for Azure Firewall.
    // AZ-104: Standard PIPs support availability zones, higher bandwidth, and
    // DDoS protection plans. Basic SKU PIPs cannot be used with Azure Firewall
    // and are being retired for most scenarios.
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    // Static allocation: The IP address is reserved at creation and never
    // changes, even after the firewall is stopped/started.
    // AZ-104: Firewall public IPs must be Static so that DNS records, allow-lists
    // in partner firewalls, and DNAT rules remain valid across maintenance windows.
    publicIPAddressVersion: 'IPv4'
    // IPv4: Azure Firewall does not support IPv6 public IPs in standard scenarios.
    // Explicitly declaring the version documents the design decision and avoids
    // ambiguity if dual-stack support is added in the future.
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  // Firewall Policy is the modern rule management plane for Azure Firewall.
  // It replaces classic 'Network Rules' and 'Application Rules' collections
  // on the firewall resource itself, enabling hierarchical policy inheritance
  // (parent policy → child policies → firewall instances).
  name: '${orgPrefix}-fwpolicy-${environment}'   // CAF naming: fwpolicy-<env>
  location: location    // Policy must reside in the same region as the firewall.
  tags: tags
  properties: {
    sku: {
      tier: environment == 'prod' ? 'Standard' : 'Basic'
      // Conditional SKU: Matches the firewall tier below.
      // AZ-104: Basic tier is significantly cheaper and suits dev/test; it lacks
      // Threat Intelligence and IDPS features. Standard tier is required for
      // production to enable threat-intel-based filtering and FQDN rules.
      // Using a ternary expression here ensures the policy and firewall SKUs
      // always stay in sync — mismatched tiers cause deployment errors.
    }
    threatIntelMode: 'Deny'
    // threatIntelMode 'Deny': Blocks traffic to/from Microsoft Threat Intelligence
    // feed IPs and FQDNs (known C2 servers, botnets, malicious actors).
    // AZ-104: Setting this to 'Deny' (vs 'Alert') actively drops malicious
    // traffic rather than just logging it — critical for a production security
    // posture. The feed is updated automatically by Microsoft.
  }
}

resource firewallPolicyRuleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  // Rule Collection Groups organise rule collections within a policy.
  // AZ-104: Groups are evaluated in ascending priority order. Within a group,
  // rule collections are evaluated by their own priority. Within a collection,
  // the first matching rule wins. This three-tier hierarchy (group → collection
  // → rule) enables granular, auditable rule lifecycle management.
  parent: firewallPolicy    // Child of firewallPolicy — the group belongs to this policy.
  name: 'DefaultNetworkRuleCollectionGroup'
  // 'Default' prefix signals this group contains baseline rules that apply
  // across all environments before more specific application rules.
  properties: {
    priority: 200
    // priority 200: Network rule groups are conventionally assigned higher
    // priority (lower number) than application rule groups (FQDN-based) because
    // they are evaluated first in Azure Firewall's processing pipeline.
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        // FilterRuleCollection: Evaluates rules and either allows or denies.
        // AZ-104: The alternative is 'FirewallPolicyNatRuleCollection' for DNAT.
        name: 'AllowInternet'
        // AllowInternet: Permits specific outbound internet traffic patterns
        // that all spokes require for basic OS and application functionality.
        priority: 100    // First collection evaluated in this group.
        action: {
          type: 'Allow'   // Permit traffic that matches any rule in this collection.
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            // NetworkRule: Layer-4 rule matching on IP, port, and protocol.
            // AZ-104: Use NetworkRule for non-HTTP(S) traffic or when you do
            // not need FQDN resolution. Use ApplicationRule for HTTP/S with
            // full FQDN filtering and TLS inspection (Standard/Premium only).
            name: 'Allow-DNS'
            // DNS (port 53) must be permitted outbound so VMs can resolve
            // public FQDNs and internal Azure Private DNS zones.
            sourceAddresses: ['10.0.0.0/8']
            // Covers the entire RFC 1918 10.x.x.x range — all hub and spoke
            // subnets. Using a supernet avoids updating this rule every time a
            // new spoke is added, as long as all spokes stay within 10.0.0.0/8.
            destinationAddresses: ['*']
            // '*' allows any DNS server — useful during bootstrapping when
            // custom DNS server IPs are not yet known. Tighten to specific IPs
            // (e.g. Azure DNS 168.63.129.16) in hardened environments.
            destinationPorts: ['53']
            // Port 53: DNS. Both TCP (for responses >512 bytes, zone transfers)
            // and UDP (standard queries) are specified in ipProtocols below.
            ipProtocols: ['TCP', 'UDP']
            // DNS uses UDP by default; falls back to TCP for large responses.
            // Both must be allowed to avoid hard-to-diagnose resolver timeouts.
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            // NTP (port 123/UDP) enables time synchronisation for all VMs.
            // AZ-104: Accurate time is critical for Kerberos authentication,
            // certificate validity checks, log correlation, and Azure AD tokens
            // (which have short validity windows). Azure VMs sync to the host
            // hypervisor by default, but allowing outbound NTP ensures VMs that
            // bypass hypervisor time sync (or nested VMs) also work correctly.
            sourceAddresses: ['10.0.0.0/8']    // All hub and spoke subnets (same supernet as DNS).
            destinationAddresses: ['*']          // Any public NTP server (pool.ntp.org etc).
            destinationPorts: ['123']            // NTP uses port 123 exclusively.
            ipProtocols: ['UDP']                 // NTP is UDP-only; TCP is not used.
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  // The Azure Firewall instance itself. This is the data-plane appliance that
  // inspects packets in real time. It is distinct from the Firewall Policy,
  // which is the control-plane rule store. Separating them allows the same
  // policy to be attached to multiple firewall instances (e.g. per-region).
  name: '${orgPrefix}-fw-${environment}'    // CAF naming: fw-<env>
  location: location    // Must be in the same region as the VNet and Public IP.
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      // AZFW_VNet: Deploys the firewall inside a VNet (as opposed to AZFW_Hub
      // used in Azure Virtual WAN). Hub-and-spoke topologies without vWAN use
      // AZFW_VNet so the firewall is reachable via VNet peering from spokes.
      tier: environment == 'prod' ? 'Standard' : 'Basic'
      // Same environment-driven tier as the policy — must match exactly.
      // AZ-104: Mismatched policy and firewall tiers cause ARM deployment errors.
    }
    firewallPolicy: {
      id: firewallPolicy.id
      // Attaches the Firewall Policy to this instance.
      // AZ-104: Using a Policy (vs classic rules) is the recommended and
      // required approach for new deployments — classic rules are deprecated.
      // The policy ID reference creates an implicit Bicep dependency so the
      // policy is fully created before the firewall attempts to attach it.
    }
    ipConfigurations: [
      {
        // IP configuration binds a public IP and a subnet to the firewall,
        // enabling both SNAT (outbound) and DNAT (inbound) functionality.
        // Multiple IP configurations can be added for additional public IPs.
        name: 'fw-ipconfig'    // Logical name for this IP configuration object.
        properties: {
          publicIPAddress: {
            id: firewallPip.id
            // Associates the Standard Static PIP created above.
            // AZ-104: Without a public IP the firewall cannot SNAT spoke traffic
            // to the internet or accept DNAT connections from external clients.
          }
          subnet: {
            id: '${hubVnet.id}/subnets/${subnets.firewall.name}'
            // Constructs the AzureFirewallSubnet resource ID by combining the
            // VNet ID with the required subnet name.
            // AZ-104: The firewall must be placed in AzureFirewallSubnet — the
            // platform assigns internal IPs from this subnet for its own use.
            // The firewall's private IP (output below) is used as the UDR
            // next-hop in spoke route tables to force-tunnel traffic.
          }
        }
      }
    ]
  }
}

// ── Firewall Diagnostics ───────────────────────────────────────────────────
// Azure Firewall generates rich telemetry: rule hit logs, threat intel alerts,
// IDPS signatures, SNAT port utilisation, and latency metrics.
// AZ-104: These logs are mandatory for security audits, incident response,
// and demonstrating compliance with frameworks like ISO 27001 or SOC 2.
// Without diagnostics, firewall allow/deny decisions are invisible.

resource firewallDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'          // Consistent name enables idempotent Policy remediation.
  scope: firewall              // Extension resource scoped to the firewall instance.
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // Sends all telemetry to the central Log Analytics workspace.
    // AZ-104: Log Analytics is the backend for Azure Monitor, Defender for
    // Cloud, and Microsoft Sentinel — centralising here means a single query
    // can correlate firewall events with VM, identity, and storage logs.
    logs: [
      {
        categoryGroup: 'allLogs'
        // 'allLogs' captures: AzureFirewallApplicationRule, AzureFirewallNetworkRule,
        // AzureFirewallDnsProxy, AzureFirewallThreatIntelLog, and any future
        // categories added by the platform — future-proofing without template changes.
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        // AllMetrics: Streams numeric time-series data including:
        //   - ApplicationRuleHit / NetworkRuleHit (rule usage tracking)
        //   - SNATPortUtilization (alert if approaching SNAT exhaustion)
        //   - Throughput (capacity planning)
        //   - FirewallHealth (uptime/health percentage)
        // AZ-104: Setting Azure Monitor alerts on SNATPortUtilization > 80%
        // and FirewallHealth < 100% is a best-practice operational pattern.
        enabled: true
      }
    ]
  }
}

// ── Azure Bastion ──────────────────────────────────────────────────────────
// Azure Bastion provides browser-based RDP and SSH access to VMs without
// requiring public IPs on individual VMs or exposing management ports to the
// internet through NSG rules or firewall DNAT.
// AZ-104: Bastion is the recommended replacement for traditional jump boxes
// because it eliminates VM management overhead, is always patched by Microsoft,
// and provides native Azure AD-integrated audit logs of every session.

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  // Bastion requires its own Standard Static PIP — it is the only ingress point
  // for RDP/SSH traffic, accepting HTTPS (443) from the Azure portal front-end.
  name: '${orgPrefix}-pip-bastion-${environment}'   // CAF naming: pip-bastion-<env>
  location: location    // Must be co-located with the Bastion host resource.
  tags: tags
  sku: {
    name: 'Standard'
    // Standard SKU is required for Azure Bastion.
    // AZ-104: Basic PIP SKUs are incompatible with Bastion. Standard SKUs also
    // support availability zone pinning (not shown here) for HA deployments.
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    // Static allocation: Bastion's public IP must be static.
    // AZ-104: The Azure portal constructs the Bastion connection URL using this
    // IP; a Dynamic IP that changed on restart would break existing bookmark URLs
    // and audit log IP-to-resource correlations.
    // Note: IPv4 is implicit when publicIPAddressVersion is not specified.
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: '${orgPrefix}-bastion-${environment}'   // CAF naming: bastion-<env>
  location: location    // Bastion must be in the same region as the VMs it manages.
  tags: tags
  sku: {
    name: 'Basic'
    // Basic SKU: Provides core RDP and SSH-in-browser functionality.
    // AZ-104: Basic is appropriate for environments where native client support,
    // file copy, and shareable links (Standard SKU features) are not required.
    // Standard SKU would be chosen for production if engineers need copy/paste
    // of large content, tunnelling, or Azure AD Conditional Access enforcement
    // at the Bastion level rather than at the VM OS level.
  }
  properties: {
    ipConfigurations: [
      {
        // Bastion requires exactly one IP configuration linking its PIP and subnet.
        name: 'bastion-ipconfig'    // Logical name — value is arbitrary but must be unique within the host.
        properties: {
          publicIPAddress: {
            id: bastionPip.id
            // References the Standard Static PIP created above.
            // AZ-104: This is the internet-facing endpoint. All user connections
            // from the Azure portal arrive at this IP over HTTPS (443), then
            // Bastion proxies the session to the target VM over the private network.
          }
          subnet: {
            id: '${hubVnet.id}/subnets/${subnets.bastion.name}'
            // Constructs the AzureBastionSubnet resource ID.
            // AZ-104: Bastion injects NICs into this subnet to communicate with
            // target VMs. The subnet must be /26 or larger to accommodate these
            // internal NICs during scale-out. No UDR should be placed on this
            // subnet as it would break the routing Bastion relies on internally.
          }
        }
      }
    ]
  }
}

// ── Private DNS Zone (for private endpoints) ───────────────────────────────
// Private DNS Zones resolve Azure service FQDNs (e.g. myaccount.blob.core.windows.net)
// to private endpoint IP addresses instead of public IPs.
// AZ-104: Without a Private DNS Zone, VMs that resolve a storage FQDN will
// get the public IP and traffic will route through the internet even if a
// private endpoint exists. The zone overrides public DNS for matched FQDNs,
// ensuring traffic stays on the private network end-to-end.
// Hosting the zone in the hub and linking it to all VNets is the recommended
// centralised DNS architecture for Hub-and-Spoke (Azure Landing Zone pattern).

resource privateDnsBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${az.environment().suffixes.storage}'
  // Dynamic FQDN construction using az.environment().suffixes.storage.
  // AZ-104: The storage FQDN suffix differs between Azure clouds:
  //   Azure Commercial : blob.core.windows.net
  //   Azure Government : blob.core.usgovcloudapi.net
  //   Azure China      : blob.core.chinacloudapi.cn
  // Using az.environment() makes this template cloud-agnostic — the correct
  // Private DNS zone name is computed at deploy time without code changes.
  // The 'privatelink.' prefix is the Microsoft-defined namespace for private
  // endpoints; all storage blob private endpoints register A records here.
  location: 'global'
  // location 'global': Private DNS Zones are global resources (not region-bound).
  // AZ-104: A global zone can be linked to VNets in any Azure region,
  // making it ideal for a hub that serves spokes across multiple regions.
  // Using 'global' is mandatory — specifying a region will cause a deployment error.
  tags: tags
}

resource privateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  // A VirtualNetworkLink registers a VNet as a resolver for this Private DNS Zone.
  // Without this link, VMs in the hub cannot use the zone for DNS resolution
  // even though the zone exists in the same subscription.
  parent: privateDnsBlob    // Child resource of the Private DNS Zone.
  name: 'link-hub'
  // 'link-hub': Descriptive name identifying this as the hub VNet link.
  // Spoke links would be named 'link-spoke-01', 'link-spoke-02', etc.
  location: 'global'        // VNet links are also global — must match the zone's location.
  properties: {
    virtualNetwork: {
      id: hubVnet.id
      // Registers the hub VNet so all VMs in hub subnets can resolve private
      // endpoint FQDNs via this zone. Spoke VNets must have their own links
      // (created in spoke modules) to benefit from centralised DNS resolution.
    }
    registrationEnabled: false
    // registrationEnabled false: Disables automatic DNS registration of VM NICs.
    // AZ-104: Auto-registration is only useful when you want every VM NIC to
    // create an A record in the zone (e.g. for internal name resolution of VMs).
    // For private endpoint zones, auto-registration is never appropriate because
    // A records are managed by the private endpoint resource itself — enabling it
    // would allow VMs to register conflicting records and pollute the zone.
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Outputs surface resource identifiers and runtime-assigned values to the
// parent/orchestrator template. Bicep resolves these only after the resource
// is fully provisioned, so downstream modules that consume these outputs have
// an implicit dependency on this module completing successfully first.
// AZ-104: Exporting IDs and IPs (rather than names) is preferred because IDs
// are globally unique and can be used directly in resource references without
// additional lookups. Names are also exported here for human-readable labelling.

output hubVnetId string = hubVnet.id
// hubVnetId: Full ARM resource ID of the hub VNet.
// AZ-104: Spoke modules use this ID in their VNet peering definitions —
// both the hub→spoke and spoke→hub peering resources need the remote VNet ID.
// Also consumed by UDR (User-Defined Route) modules that specify VNet scope.

output hubVnetName string = hubVnet.name
// hubVnetName: Friendly display name of the hub VNet.
// Useful for portal navigation, Azure Monitor workbook titles, and any ARM
// template that needs the name rather than the full resource ID.

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
// firewallPrivateIp: The private IP Azure assigned to the firewall inside AzureFirewallSubnet.
// AZ-104: This is the next-hop IP used in every spoke's User-Defined Route (UDR)
// to force-tunnel traffic through the firewall.  The address is assigned by
// Azure (it will always be the fourth IP in the AzureFirewallSubnet CIDR, e.g.
// 10.0.1.4 for a 10.0.1.0/26 subnet) and is retrieved here at deploy time so
// spoke route tables are built with the correct value without hard-coding.

output bastionPublicIp string = bastionPip.properties.ipAddress
// bastionPublicIp: The internet-facing IP address of Azure Bastion.
// AZ-104: Useful for allow-listing Bastion's egress IP in external SaaS
// audit logs, and for documenting the management access entry point in
// network architecture diagrams and compliance evidence packages.

output privateDnsZoneId string = privateDnsBlob.id
// privateDnsZoneId: Resource ID of the blob Private DNS Zone.
// AZ-104: Storage Account private endpoint modules use this ID to register
// their A records in the correct zone. Spoke VNet link modules also use it
// to create their own VirtualNetworkLink child resources, ensuring all spoke
// VMs resolve storage FQDNs to private endpoint IPs via the centralised zone.
