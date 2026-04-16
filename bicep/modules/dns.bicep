// ============================================================================
// Azure DNS — Public zone, record sets, alias records, Private DNS
// AZ-104 Domain: Configure and manage virtual networking
// Azure DNS hosts DNS zones in Azure infrastructure, providing the same SLA and
// global redundancy as other Azure services. Public zones are internet-resolvable;
// private zones resolve only within linked VNets.
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Deployment environment (dev / staging / prod) — used in zone/record names
param environment string

// Short organization prefix used to build zone and record names
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// ARM resource ID of the public load balancer's frontend IP; used as the alias
// target for the www A record (alias records auto-update if the IP changes)
param webLbPublicIpId string

// ── Public DNS Zone ────────────────────────────────────────────────────────
// A DNS zone delegates authority for a domain name to Azure name servers.
// After deployment, update the registrar NS records to the four Azure name
// servers emitted in the publicDnsNameServers output.

resource publicDnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' = {
  // Zone name must be a valid fully-qualified domain name (FQDN).
  // Replace 'example.com' with the actual registered domain before deployment.
  name: '${orgPrefix}-${environment}.example.com'     // Replace with real domain
  // DNS zones are global resources — 'global' is the only valid location
  location: 'global'
  tags: tags
  properties: {
    // 'Public' zone = internet-resolvable; contrast with Private zones below
    zoneType: 'Public'
  }
}

// ── A Record (alias to load balancer public IP) ───────────────────────────
// Alias A records point to Azure resource IDs rather than hard-coded IPs.
// When the LB IP changes (e.g. after a redeploy), the DNS record updates
// automatically — no manual TTL-wait required.

resource wwwAlias 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = {
  // parent links this record set to the public zone above
  parent: publicDnsZone
  // Record set name 'www' resolves to www.<zone-name>
  name: 'www'
  properties: {
    // TTL in seconds; 300 = 5 minutes. Lower TTL allows faster failover
    // but increases DNS query load and resolver cache churn.
    TTL: 300
    targetResource: {
      // Alias target — ARM resource ID of the public IP; Azure DNS resolves
      // the current IP address at query time from the resource's properties
      id: webLbPublicIpId
    }
  }
}

// ── A Record (static IP) ──────────────────────────────────────────────────
// Static A records map a hostname to one or more explicit IPv4 addresses.
// Unlike alias records, these do NOT auto-update if the IP changes.

resource apiRecord 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = {
  parent: publicDnsZone
  // 'api' resolves to api.<zone-name>
  name: 'api'
  properties: {
    // 300-second TTL balances responsiveness to IP changes vs resolver caching
    TTL: 300
    ARecords: [
      // This RFC-1918 private address is only reachable via Private DNS or
      // split-horizon DNS; internet clients will receive this record but cannot
      // route to it — intentional for internal-only API endpoints
      { ipv4Address: '10.2.1.10' }       // Internal — only resolves via Private DNS
    ]
  }
}

// ── CNAME Record ──────────────────────────────────────────────────────────
// CNAME (Canonical Name) creates an alias from cdn.<zone> to the Azure CDN
// endpoint hostname. CDN endpoints require CNAME mapping for custom domains.
// Note: CNAME records cannot be created at the zone apex (@); use an alias A
// record there instead.

resource cdnCname 'Microsoft.Network/dnsZones/CNAME@2023-07-01-preview' = {
  parent: publicDnsZone
  // 'cdn' resolves to cdn.<zone-name>
  name: 'cdn'
  properties: {
    // 3600-second (1 hour) TTL; CDN endpoints are stable so longer TTL is fine
    TTL: 3600
    CNAMERecord: {
      // The Azure CDN endpoint hostname automatically assigned to this profile.
      // The trailing dot is omitted here but resolvers treat it as absolute.
      cname: '${orgPrefix}-${environment}.azureedge.net'
    }
  }
}

// ── MX Record ─────────────────────────────────────────────────────────────
// MX (Mail Exchanger) records direct inbound email for the domain to mail
// servers. Lower preference value = higher priority. Two records provide
// failover if the primary mail server is unavailable.

resource mxRecord 'Microsoft.Network/dnsZones/MX@2023-07-01-preview' = {
  parent: publicDnsZone
  // '@' represents the zone apex (the root domain itself, e.g. contoso.com)
  name: '@'
  properties: {
    // 3600-second TTL; mail routing is stable so a longer TTL reduces query load
    TTL: 3600
    MXRecords: [
      // Primary mail server — lower preference (10) = tried first
      { preference: 10, exchange: 'mail.example.com.' }
      // Secondary mail server — higher preference (20) = used as failover
      { preference: 20, exchange: 'mail2.example.com.' }
    ]
  }
}

// ── TXT Record (SPF) ─────────────────────────────────────────────────────
// TXT records carry arbitrary text data. The SPF (Sender Policy Framework)
// record tells receiving mail servers which hosts are authorized to send email
// on behalf of this domain, reducing spam/phishing spoofing.

resource txtSpf 'Microsoft.Network/dnsZones/TXT@2023-07-01-preview' = {
  parent: publicDnsZone
  // '@' = zone apex; SPF records must live at the sending domain's apex
  name: '@'
  properties: {
    // 3600-second TTL; SPF records rarely change
    TTL: 3600
    TXTRecords: [
      {
        // SPF record: authorizes Microsoft Exchange Online (Office 365) to send
        // mail for this domain; '-all' hard-fails unauthorized senders
        value: ['v=spf1 include:spf.protection.outlook.com -all']
      }
    ]
  }
}

// ── Private DNS Zone (internal resolution) ─────────────────────────────────
// Private DNS zones resolve only within Azure VNets that are linked to them.
// Used for split-horizon DNS: internal clients resolve private IPs while
// internet clients see public IPs (or nothing, for internal-only services).
// Private DNS zones must be linked (VNet link) to each VNet that needs resolution.

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  // Private zone names can use any valid DNS name; convention is to use a
  // non-routable TLD such as .internal, .corp, or .local to distinguish from
  // internet-resolvable zones
  name: '${orgPrefix}.internal.${environment}'
  // Private DNS zones are also global resources
  location: 'global'
  tags: tags
}

// Private A record within the private zone pointing to the internal load
// balancer frontend IP. VMs with the private zone linked can resolve
// 'app-lb.<orgPrefix>.internal.<env>' to reach the LB without going public.
resource privateARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  // parent links this record set to the private zone above
  parent: privateDnsZone
  // Hostname 'app-lb' resolves to app-lb.<private-zone-name>
  name: 'app-lb'
  properties: {
    // 300-second TTL for private records; shorter TTL supports faster failover
    // during maintenance or IP reassignment
    ttl: 300
    aRecords: [
      // RFC-1918 address of the internal load balancer frontend IP configuration;
      // only reachable from within the VNet or peered VNets
      { ipv4Address: '10.2.1.4' }       // Internal LB frontend IP
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

// ARM resource ID of the public DNS zone; used to scope DNS Contributor RBAC
// assignments or to add further record sets from other modules
output publicDnsZoneId string = publicDnsZone.id

// Array of four Azure-assigned authoritative name server hostnames.
// These must be configured as NS records at the domain registrar to delegate
// DNS authority for the zone to Azure DNS.
output publicDnsNameServers array = publicDnsZone.properties.nameServers

// ARM resource ID of the private DNS zone; used to create VNet links so that
// VMs in each VNet can resolve records in this zone
output privateDnsZoneId string = privateDnsZone.id
