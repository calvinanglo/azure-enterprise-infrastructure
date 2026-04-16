// ============================================================================
// Azure DNS — Public zone, record sets, alias records, Private DNS
// AZ-104 Domain: Configure and manage virtual networking
// ============================================================================

param environment string
param orgPrefix string
param tags object
param webLbPublicIpId string

// ── Public DNS Zone ────────────────────────────────────────────────────────

resource publicDnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' = {
  name: '${orgPrefix}-${environment}.example.com'     // Replace with real domain
  location: 'global'
  tags: tags
  properties: {
    zoneType: 'Public'
  }
}

// ── A Record (alias to load balancer public IP) ───────────────────────────

resource wwwAlias 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = {
  parent: publicDnsZone
  name: 'www'
  properties: {
    TTL: 300
    targetResource: {
      id: webLbPublicIpId
    }
  }
}

// ── A Record (static IP) ──────────────────────────────────────────────────

resource apiRecord 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = {
  parent: publicDnsZone
  name: 'api'
  properties: {
    TTL: 300
    ARecords: [
      { ipv4Address: '10.2.1.10' }       // Internal — only resolves via Private DNS
    ]
  }
}

// ── CNAME Record ──────────────────────────────────────────────────────────

resource cdnCname 'Microsoft.Network/dnsZones/CNAME@2023-07-01-preview' = {
  parent: publicDnsZone
  name: 'cdn'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: '${orgPrefix}-${environment}.azureedge.net'
    }
  }
}

// ── MX Record ─────────────────────────────────────────────────────────────

resource mxRecord 'Microsoft.Network/dnsZones/MX@2023-07-01-preview' = {
  parent: publicDnsZone
  name: '@'
  properties: {
    TTL: 3600
    MXRecords: [
      { preference: 10, exchange: 'mail.example.com.' }
      { preference: 20, exchange: 'mail2.example.com.' }
    ]
  }
}

// ── TXT Record (SPF) ─────────────────────────────────────────────────────

resource txtSpf 'Microsoft.Network/dnsZones/TXT@2023-07-01-preview' = {
  parent: publicDnsZone
  name: '@'
  properties: {
    TTL: 3600
    TXTRecords: [
      { value: ['v=spf1 include:spf.protection.outlook.com -all'] }
    ]
  }
}

// ── Private DNS Zone (internal resolution) ─────────────────────────────────

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: '${orgPrefix}.internal.${environment}'
  location: 'global'
  tags: tags
}

resource privateARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: 'app-lb'
  properties: {
    ttl: 300
    aRecords: [
      { ipv4Address: '10.2.1.4' }       // Internal LB frontend IP
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output publicDnsZoneId string = publicDnsZone.id
output publicDnsNameServers array = publicDnsZone.properties.nameServers
output privateDnsZoneId string = privateDnsZone.id
