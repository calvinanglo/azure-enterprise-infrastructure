// ============================================================================
// Load Balancers — Public (web tier) + Internal (app tier)
// AZ-104 scope: Implement and manage virtual networking + Monitor and back up
// Azure resources. Demonstrates Standard SKU LB design, health probes,
// outbound SNAT rules, and diagnostic settings sent to Log Analytics.
// ============================================================================

// location: Azure region for all resources in this module.
// Passed from the parent template so every resource lands in the same region,
// which avoids cross-region egress charges and latency.
param location string

// environment: Logical tier label (e.g. 'dev', 'prod').
// Used as a naming suffix so resources from different environments never
// collide in the same subscription — a key governance practice under AZ-104.
param environment string

// orgPrefix: Short organisational identifier prepended to every resource name.
// Ensures names are globally unique and instantly attributable to the org —
// critical when managing many subscriptions in a Management Group hierarchy.
param orgPrefix string

// tags: Key-value metadata object applied to every resource.
// Tags are the primary mechanism for cost management, chargeback, and policy
// enforcement (Azure Policy 'Require tag' initiatives) in AZ-104 governance.
param tags object

// webSubnetId: Resource ID of the web-tier subnet — passed in but not directly
// used by the PUBLIC load balancer (which uses a PIP, not a subnet).
// Retained as a parameter so the module signature stays symmetric and callers
// can audit which subnets are in scope for this LB pair.
param webSubnetId string

// appSubnetId: Resource ID of the app-tier subnet used by the INTERNAL LB's
// frontend IP. The ILB front-end must sit inside a VNet subnet so it gets a
// private RFC-1918 address reachable only from within the virtual network.
param appSubnetId string

// logAnalyticsWorkspaceId: Resource ID of the central Log Analytics Workspace.
// AZ-104 requires understanding Azure Monitor integration — all LB metrics are
// forwarded here for unified monitoring, alerting, and audit trail.
param logAnalyticsWorkspaceId string

// ── Public Load Balancer (Web Tier) ────────────────────────────────────────
// The public LB faces the internet and distributes inbound HTTP/HTTPS traffic
// across the web-tier VM scale set backend pool. AZ-104 topic: Configure and
// manage Azure Load Balancer (Standard SKU, public-facing).

// webLbPip: Public IP address resource that becomes the internet-facing VIP
// of the web load balancer. A dedicated PIP resource is required so it can be
// referenced independently (e.g. in DNS, NSG rules, or outputs).
resource webLbPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  // Naming convention: <org>-pip-lb-web-<env> clearly identifies this as a
  // Public IP (pip) used by the load balancer (lb) for the web tier.
  name: '${orgPrefix}-pip-lb-web-${environment}'

  // Same region as the LB — a PIP must be co-located with the resource using it.
  location: location

  // Propagate governance tags to the PIP so cost reports include it correctly.
  tags: tags

  // Standard SKU: required when attaching to a Standard SKU Load Balancer.
  // Standard PIPs are zone-redundant by default and support availability zones,
  // unlike Basic SKU. AZ-104: Standard SKU is the only production-grade choice.
  sku: { name: 'Standard' }

  properties: {
    // Static allocation: the IP address is reserved at creation and never
    // changes across stop/start cycles. Required for LB front-ends because DNS
    // entries and firewall rules must remain valid indefinitely.
    publicIPAllocationMethod: 'Static'

    // IPv4: the address family for this PIP. IPv6 dual-stack is possible on
    // Standard LBs but is a separate configuration; here we use IPv4-only to
    // keep the design straightforward.
    publicIPAddressVersion: 'IPv4'
  }
}

// webLb: Standard Public Load Balancer for the web tier.
// Receives internet traffic on ports 80 and 443, health-checks backends,
// and distributes connections across all healthy VMs in the backend pool.
// The Standard SKU is mandatory for production: it is zone-redundant, SLA-
// backed (99.99%), and required for Availability Zone deployments (AZ-104).
resource webLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  // Naming: <org>-lb-web-<env> — 'lb' denotes load balancer, 'web' the tier.
  name: '${orgPrefix}-lb-web-${environment}'

  location: location
  tags: tags

  // Standard SKU: required for zone-redundancy, outbound rules, and HA ports.
  // Cannot be mixed with Basic SKU resources — all NICs in the backend pool
  // must also have Standard SKU PIPs or no PIPs at all.
  sku: { name: 'Standard' }

  properties: {

    // ── Frontend IP Configurations ──────────────────────────────────────────
    // Defines the VIP(s) that clients connect to. A single Standard LB can
    // have multiple frontends, each with its own IP, enabling port sharing
    // across independent services on the same LB instance.
    frontendIPConfigurations: [
      {
        // Logical name referenced by load-balancing rules and outbound rules
        // via resourceId() — must be unique within this LB.
        name: 'web-frontend'
        properties: {
          // Binds this frontend to the public IP created above.
          // Using the symbolic reference (.id) establishes an implicit
          // dependency so Bicep deploys the PIP before this LB.
          publicIPAddress: { id: webLbPip.id }
        }
      }
    ]

    // ── Backend Address Pools ───────────────────────────────────────────────
    // The pool is a logical container; actual membership is set on the NIC
    // (or VMSS network profile) by referencing this pool's resource ID.
    // AZ-104: backend pool membership drives which VMs receive traffic.
    backendAddressPools: [
      { name: 'web-backend-pool' }
    ]

    // ── Health Probes ───────────────────────────────────────────────────────
    // Probes continuously test backend health. Only healthy instances receive
    // new connections. AZ-104: understand probe types (HTTP vs TCP) and how
    // 'numberOfProbes' + 'probeThreshold' define the up/down state transitions.
    probes: [
      {
        name: 'http-probe'
        properties: {
          // HTTP probe: sends a GET request and expects a 2xx response.
          // More precise than a TCP probe because it validates application
          // readiness, not just that the port is open.
          protocol: 'Http'

          // Port the LB probes on each backend VM. Must match the port the
          // web server listens on for health-check requests.
          port: 80

          // Path the HTTP GET targets. The app must return HTTP 2xx at this
          // endpoint when healthy — a dedicated /health route is best practice
          // so a single slow page doesn't mark the whole VM unhealthy.
          requestPath: '/health'

          // How often (seconds) the LB sends a probe packet to each backend.
          // Lower = faster failover detection; higher = less probe traffic.
          intervalInSeconds: 15

          // Number of consecutive probe results the LB evaluates per cycle.
          // Combined with probeThreshold this controls sensitivity.
          numberOfProbes: 2

          // Minimum number of successful probes in a window required to mark a
          // backend healthy (or keep it healthy). A value of 1 means one
          // successful probe is enough to restore a backend after it was down.
          probeThreshold: 1
        }
      }
    ]

    // ── Load Balancing Rules ────────────────────────────────────────────────
    // Each rule maps a <frontend IP : frontend port> to a <backend pool :
    // backend port> and associates a health probe. AZ-104: rules are stateless
    // at the LB layer — session persistence (if needed) is set via
    // loadDistribution (not used here, so default 5-tuple hash applies).
    loadBalancingRules: [
      {
        // HTTP rule: accepts plain-text web traffic on port 80.
        // In production you would typically redirect 80→443 at the app layer
        // or via an Application Gateway WAF policy.
        name: 'http-rule'
        properties: {
          // References the frontend IP by fully-qualified resource ID.
          // resourceId() constructs the ARM ID at deploy time — safer than
          // hard-coding subscription/RG paths.
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
          }

          // Directs matched traffic into the web backend pool.
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }

          // Associates the HTTP health probe — unhealthy VMs are removed from
          // the rotation for this rule automatically.
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-web-${environment}', 'http-probe')
          }

          // Tcp: operates at Layer 4. The LB does NOT inspect HTTP headers;
          // SSL offload or L7 routing requires Azure Application Gateway.
          protocol: 'Tcp'

          // frontendPort: the port clients connect to on the LB's VIP.
          frontendPort: 80

          // backendPort: the port traffic is forwarded to on each backend VM.
          // Here frontend and backend ports are equal (both 80), which is the
          // most common configuration.
          backendPort: 80

          // Floating IP (Direct Server Return): disabled. When false, the LB
          // rewrites the destination IP to the VM's NIC IP. Floating IP is
          // only needed for SQL Server AlwaysOn AG listeners or similar HA
          // scenarios. Keeping it false simplifies VM network configuration.
          enableFloatingIP: false

          // TCP idle timeout in minutes. Connections idle longer than this are
          // reset. 4 minutes is the minimum; increase for long-lived sessions
          // (e.g. WebSocket). Must be coordinated with app keep-alive settings.
          idleTimeoutInMinutes: 4

          // disableOutboundSnat: true — explicitly prevents this load-balancing
          // rule from providing automatic outbound SNAT to backend VMs.
          // CRITICAL AZ-104 concept: when an explicit outbound rule exists (see
          // below) you MUST set this to true on every inbound rule; otherwise
          // the two SNAT mechanisms conflict and port exhaustion can occur.
          disableOutboundSnat: true
        }
      }
      {
        // HTTPS rule: handles TLS-encrypted web traffic on port 443.
        // Same probe, same backend pool as HTTP — both rules share the pool.
        name: 'https-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }
          // Reuses the HTTP probe on port 80. The LB probes the health endpoint
          // over plain HTTP even though user traffic arrives over HTTPS — this
          // is intentional and avoids TLS certificate management on the probe.
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-web-${environment}', 'http-probe')
          }
          protocol: 'Tcp'

          // frontendPort 443: TLS connections arrive here from the internet.
          frontendPort: 443

          // backendPort 443: traffic is forwarded unmodified to the backend.
          // TLS termination happens on each VM (pass-through mode), meaning the
          // VM must hold the TLS certificate. For centralised TLS termination,
          // use Application Gateway instead.
          backendPort: 443

          enableFloatingIP: false
          idleTimeoutInMinutes: 4

          // Must also be true here — same SNAT conflict reason as the http-rule.
          disableOutboundSnat: true
        }
      }
    ]

    // ── Outbound Rules ──────────────────────────────────────────────────────
    // Outbound rules give backend VMs internet access through the LB's PIP
    // using SNAT (Source Network Address Translation). AZ-104: with Standard
    // SKU LBs, backend VMs that have NO instance-level PIP need an explicit
    // outbound rule or they cannot reach the internet at all (unlike Basic SKU
    // which provides implicit outbound). This is a deliberate security design:
    // no unintentional outbound access without an explicit rule.
    outboundRules: [
      {
        name: 'web-outbound'
        properties: {
          // The PIP(s) used as the source address for outbound traffic from
          // backend VMs. Multiple frontend IPs could be listed here to increase
          // the available SNAT port pool (each IP provides up to 64,512 ports).
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-web-${environment}', 'web-frontend')
            }
          ]

          // Backend pool whose VMs receive outbound SNAT via this rule.
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-web-${environment}', 'web-backend-pool')
          }

          // 'All' covers both TCP and UDP outbound traffic. Use 'Tcp' or 'Udp'
          // to restrict which protocol gets SNAT if required by policy.
          protocol: 'All'

          // enableTcpReset: sends TCP RST to both sides when an idle connection
          // hits the timeout. This prevents half-open connection hangs on VMs
          // and load-test tools — strongly recommended for production workloads.
          enableTcpReset: true

          // Idle timeout for outbound flows. Aligned with the inbound rule (4m).
          idleTimeoutInMinutes: 4

          // Per-backend-instance SNAT port allocation. 1024 ports per VM means
          // ~63 simultaneous outbound connections per destination IP. Increase
          // if VMs make many concurrent outbound calls (e.g. microservices
          // calling external APIs), but note the total port budget per frontend
          // PIP is fixed at 64,512 — more ports per VM = fewer supported VMs.
          allocatedOutboundPorts: 1024
        }
      }
    ]
  }
}

// ── Internal Load Balancer (App Tier) ──────────────────────────────────────
// The internal (private) LB sits between the web tier and the application tier.
// It has NO public IP — its frontend IP is a private address inside the VNet.
// This enforces the classic 3-tier security pattern: the app tier is never
// directly reachable from the internet. AZ-104: understand when to use an
// internal vs public LB and how private front-end IPs integrate with VNet routing.

// appLb: Standard Internal Load Balancer for the application tier.
// Web-tier VMs send traffic to appLb's private VIP; the LB distributes it
// across healthy app-tier VMs. Because it is internal, no outbound rules are
// needed — app VMs use the web LB's SNAT or a NAT Gateway for egress.
resource appLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  // Naming: <org>-lb-app-<env> — 'app' distinguishes this from the web LB.
  name: '${orgPrefix}-lb-app-${environment}'

  location: location
  tags: tags

  // Standard SKU: required for zone-redundancy and HA port rules.
  // Also required so this ILB can be peered with Azure Private Link services.
  sku: { name: 'Standard' }

  properties: {

    // ── Frontend IP Configurations ──────────────────────────────────────────
    // Internal LB frontends reference a SUBNET (not a public IP). Azure assigns
    // a private IP from that subnet's address space to act as the VIP.
    frontendIPConfigurations: [
      {
        name: 'app-frontend'
        properties: {
          // The app-tier subnet provides the IP pool from which the frontend
          // address is drawn. This ties the LB VIP to the correct network
          // segment and ensures only traffic routed into this subnet can reach it.
          subnet: { id: appSubnetId }

          // Dynamic allocation: Azure picks an available IP from the subnet.
          // Use 'Static' with a specific privateIPAddress if you need a
          // predictable VIP to hard-code in application config or UDRs.
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]

    // ── Backend Address Pools ───────────────────────────────────────────────
    // Same concept as the public LB — app-tier VMs join this pool via their NIC
    // configuration. The pool name is referenced in VMSS or NIC deployments.
    backendAddressPools: [
      { name: 'app-backend-pool' }
    ]

    // ── Health Probes ───────────────────────────────────────────────────────
    // TCP probe used here (instead of HTTP) because the app tier may not expose
    // a plain-HTTP health endpoint — it might use a proprietary protocol or
    // mutual TLS. A TCP probe simply verifies the port is accepting connections.
    probes: [
      {
        name: 'app-health-probe'
        properties: {
          // TCP probe: attempts a 3-way handshake on the specified port.
          // If the connection succeeds the backend is considered healthy.
          // No response body is inspected — use an HTTP probe for deeper checks.
          protocol: 'Tcp'

          // Port 8080: common non-privileged alternative to 80 for internal
          // application services. Avoids requiring root/admin privileges to bind.
          port: 8080

          // Probe every 15 seconds — balances detection speed vs probe overhead.
          intervalInSeconds: 15

          // Evaluate 2 probe results per state-change decision cycle.
          numberOfProbes: 2

          // 1 successful probe is sufficient to restore a backend instance after
          // it was marked unhealthy. A higher value adds hysteresis (slower
          // recovery) which can prevent flapping in unstable environments.
          probeThreshold: 1
        }
      }
    ]

    // ── Load Balancing Rules ────────────────────────────────────────────────
    // Single rule forwarding app-tier traffic. No outbound rule needed for an
    // internal LB — there is no internet-facing SNAT to configure.
    loadBalancingRules: [
      {
        name: 'app-rule'
        properties: {
          // References the internal frontend IP (private VIP in the app subnet).
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${orgPrefix}-lb-app-${environment}', 'app-frontend')
          }

          // Distributes accepted traffic across the app backend pool.
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${orgPrefix}-lb-app-${environment}', 'app-backend-pool')
          }

          // Links the TCP health probe so unhealthy backends are excluded
          // from the rotation automatically without manual intervention.
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${orgPrefix}-lb-app-${environment}', 'app-health-probe')
          }

          // Layer-4 TCP forwarding — same as the public LB rules.
          protocol: 'Tcp'

          // Frontend port 8080: web-tier VMs connect to <appLb-VIP>:8080.
          frontendPort: 8080

          // Backend port 8080: forwarded directly to the app-tier VMs.
          // Port symmetry (same frontend and backend port) simplifies
          // firewall rules and application logging on the backend VMs.
          backendPort: 8080

          // Floating IP disabled — standard destination NAT to the VM's NIC IP.
          enableFloatingIP: false

          // 4-minute idle timeout, consistent with the public LB.
          // Internal east-west connections are often short-lived, so 4m is
          // sufficient; long-running streaming calls would need a higher value.
          idleTimeoutInMinutes: 4
          // NOTE: disableOutboundSnat is intentionally omitted here because
          // internal LBs do not perform outbound SNAT — the property is only
          // meaningful on public-facing load balancers with outbound rules.
        }
      }
    ]
  }
}

// ── LB Diagnostics ────────────────────────────────────────────────────────
// Diagnostic settings route telemetry (metrics and/or logs) from an Azure
// resource to one or more destinations: Log Analytics Workspace, Storage
// Account, or Event Hub. AZ-104 exam topic: Configure Azure Monitor diagnostic
// settings and understand what data each category captures.
// Both LBs forward to the same central LAW — centralised log management is a
// best practice for correlation, alerting, and compliance audit trails.

// webLbDiag: Diagnostic setting scoped to the PUBLIC load balancer.
// 'scope' ties this setting to webLb — without scope it would target the
// module's resource group, which is incorrect for child-style resources.
resource webLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  // 'send-to-law' is a conventional name indicating the destination.
  // Only one diagnostic setting per destination type is allowed per resource —
  // deploying a second setting with a different name to the same workspace
  // would create a separate (additive) setting, not replace this one.
  name: 'send-to-law'

  // Scopes the diagnostic setting to the web LB resource — Bicep resolves this
  // to the correct ARM resource ID so the setting appears under that resource
  // in the portal (Monitoring > Diagnostic settings).
  scope: webLb

  properties: {
    // Destination: Log Analytics Workspace.
    // Metrics land in the AzureMetrics table; they can then be queried with
    // KQL, used in Azure Monitor alert rules, and visualised in workbooks.
    workspaceId: logAnalyticsWorkspaceId

    // Metrics block: enables collection of all available metric categories.
    // For Azure Load Balancer, 'AllMetrics' includes: Data Path Availability
    // (measures LB health probe success rate), Health Probe Status per backend,
    // byte/packet counts, and SNAT connection counts — all critical for
    // capacity planning and incident diagnosis.
    metrics: [
      {
        // 'AllMetrics' is the catch-all category supported by most Azure
        // resource types. Using it future-proofs the setting against new
        // metrics added by the platform without requiring a template update.
        category: 'AllMetrics'

        // Explicitly enable collection. Setting to false would disable the
        // category without removing the entry — useful for temporary disablement.
        enabled: true
      }
    ]
    // NOTE: Standard Load Balancer does not emit resource logs (only metrics),
    // so no 'logs' block is needed here. Resource logs ARE available for
    // Application Gateway, Firewall, etc. — a common AZ-104 exam distinction.
  }
}

// appLbDiag: Identical diagnostic configuration for the INTERNAL load balancer.
// Separate resource required — diagnostic settings are per-resource, not
// inherited. Both LBs sending to the same LAW enables cross-tier correlation
// (e.g. correlate web LB probe failures with app LB probe failures).
resource appLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  // Same name as webLbDiag is fine because 'scope' makes each setting unique
  // within its parent resource's namespace, not globally.
  name: 'send-to-law'

  // Scoped to the internal app LB.
  scope: appLb

  properties: {
    // Same LAW destination — enables unified querying across both tiers.
    workspaceId: logAnalyticsWorkspaceId

    metrics: [
      {
        // Captures internal LB metrics: Data Path Availability and backend
        // Health Probe Status are especially valuable for East-West traffic
        // monitoring between web and app tiers.
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Outputs expose resource attributes to the parent (calling) template.
// AZ-104 context: outputs replace the need to hard-code resource IDs across
// templates, enabling loosely-coupled modular Bicep architectures. The parent
// template passes backend pool IDs to VMSS modules so VMs are automatically
// enrolled in the correct pool at deployment time.

// webLbPublicIp: The resolved public IPv4 address string of the web LB VIP.
// Used by the parent template to register the address in DNS (e.g. Azure DNS
// A record) or output it to the operator so they can verify connectivity.
output webLbPublicIp string = webLbPip.properties.ipAddress

// webLbPublicIpId: Full ARM resource ID of the Public IP resource.
// Passed to NSG rules, Azure DDoS Protection plans, or other resources that
// need to reference the PIP object rather than its resolved IP string.
output webLbPublicIpId string = webLbPip.id

// webLbBackendPoolId: ARM resource ID of the web tier backend pool.
// VMSS or individual VM NIC resources in the web tier reference this ID in
// their ipConfigurations.loadBalancerBackendAddressPools array to join the pool.
// Indexing [0] is safe because this template defines exactly one backend pool.
output webLbBackendPoolId string = webLb.properties.backendAddressPools[0].id

// appLbBackendPoolId: ARM resource ID of the app tier backend pool.
// Same pattern as webLbBackendPoolId — passed to the app-tier VMSS or NIC
// Bicep module so app VMs are enrolled in the internal LB's pool at deploy time.
output appLbBackendPoolId string = appLb.properties.backendAddressPools[0].id
