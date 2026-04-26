// ============================================================================
// VPN Gateway — Basic SKU, Point-to-Site (P2S) demonstration
// AZ-104 Domain: Networking — hybrid connectivity
// ============================================================================
// AZ-104 Context: Azure VPN Gateway provides cross-premises connectivity in
// three flavours: Site-to-Site (S2S, on-prem network ↔ Azure VNet via IPsec),
// Point-to-Site (P2S, individual client ↔ Azure VNet via OpenVPN/IKEv2/SSTP),
// and VNet-to-VNet (Azure-to-Azure across regions/tenants).
//
// This module deploys a Basic SKU gateway configured for P2S only — the
// cheapest deployment that still exercises the AZ-104 hybrid connectivity
// pattern. Basic SKU restrictions:
//   - SSTP only (no OpenVPN or IKEv2)
//   - 128 concurrent connections max
//   - 100 Mbps aggregate throughput
//   - No BGP, no zone-redundancy, no active-active
// These are fine for a demo / portfolio screenshot; production deployments
// should use VpnGw1 or higher.
//
// Cost: Basic SKU ~$27/mo (US East 2), no per-GB charge below 1 TB egress.
// Tear down after capturing the screenshot if budget is tight.
//
// Prerequisite: hub VNet must already have a GatewaySubnet (10.0.3.0/27) —
// supplied by the existing hub-network module.

// -- Parameters --------------------------------------------------------------

// Azure region — gateway is region-bound; client connections are routed to
// this region's gateway endpoint regardless of where the client connects from.
param location string

// Deployment environment for naming consistency with other resources.
param environment string

// Org prefix for CAF naming alignment (ent-vpngw-prod).
param orgPrefix string

// Tag object inherited from main.bicep.
param tags object

// Resource ID of the hub VNet that hosts the GatewaySubnet. The gateway
// resource is created in the same resource group as the VNet but its IP
// configuration references the GatewaySubnet by full resource ID.
param hubVnetId string

// ── Public IP for the VPN Gateway ──────────────────────────────────────────
// AZ-104 Context: VPN Gateway requires a Static Standard public IP for
// VpnGw1+ SKUs but allows Dynamic Basic public IP for the Basic SKU. The
// Basic public IP is free with the gateway, so we use Dynamic here to match.

resource vpnGwPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  // Public IP naming: <prefix>-pip-vpngw-<env>
  name: '${orgPrefix}-pip-vpngw-${environment}'
  location: location
  tags: tags
  sku: {
    // Basic SKU public IP — paired with Basic SKU VPN Gateway. Standard SKU
    // public IPs cannot be associated with Basic SKU gateways and vice versa.
    name: 'Basic'
  }
  properties: {
    // Dynamic allocation = IP changes if the gateway is deallocated. For a
    // P2S demo this is acceptable; production uses Static for stable DNS.
    publicIPAllocationMethod: 'Dynamic'
  }
}

// ── VPN Gateway Resource ───────────────────────────────────────────────────
// Gateway provisioning takes 30-45 minutes — the longest-deploying resource
// in the entire project. Plan deployment time accordingly.

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  // Gateway naming: <prefix>-vpngw-<env>
  name: '${orgPrefix}-vpngw-${environment}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'gw-ipconfig'
        properties: {
          // Reference to the public IP created above.
          publicIPAddress: { id: vpnGwPip.id }
          // Dynamic private IP allocation within the GatewaySubnet — required
          // by Azure (gateway can't use static private IPs).
          privateIPAllocationMethod: 'Dynamic'
          // GatewaySubnet ID — Azure REQUIRES this exact subnet name for any
          // VPN/ExpressRoute gateway. The existing hub VNet already has a
          // /27 GatewaySubnet at 10.0.3.0/27.
          subnet: { id: '${hubVnetId}/subnets/GatewaySubnet' }
        }
      }
    ]
    // 'Vpn' for VPN gateways; 'ExpressRoute' for ExpressRoute gateways. A
    // VNet can have one of each but not two of the same type.
    gatewayType: 'Vpn'
    // 'RouteBased' is required for P2S and for most modern S2S scenarios.
    // 'PolicyBased' is legacy IKEv1 only and supports only one S2S tunnel.
    vpnType: 'RouteBased'
    // Basic SKU — minimum cost, P2S SSTP only, no BGP, no zone redundancy.
    sku: {
      name: 'Basic'
      tier: 'Basic'
    }
    // No BGP — Basic SKU doesn't support it anyway.
    enableBgp: false
    // P2S configuration.
    vpnClientConfiguration: {
      // Address pool for assigned client IPs. Must NOT overlap with any VNet
      // address space. 172.16.50.0/24 is in the RFC 1918 link-local range used
      // for VPN client tunnels in this project — different from the workload
      // VNets (10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/16).
      vpnClientAddressPool: {
        addressPrefixes: ['172.16.50.0/24']
      }
      // SSTP is the only protocol Basic SKU supports. OpenVPN and IKEv2
      // require VpnGw1+ (~$140/mo). SSTP works on Windows clients only.
      vpnClientProtocols: ['SSTP']
      // Root certificate placeholder — real deployments paste a base64
      // public certificate here so the gateway can validate client certs.
      // Empty array = no client certs registered yet; admin must upload one
      // post-deploy via the Azure Portal "Point-to-site configuration" blade
      // before any client can connect. This intentional 2-phase approach
      // means the Bicep doesn't embed cert material.
      vpnClientRootCertificates: []
    }
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output vpnGatewayId string = vpnGateway.id
output vpnGatewayName string = vpnGateway.name
output vpnGatewayPublicIp string = vpnGwPip.id
