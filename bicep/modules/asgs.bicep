// ============================================================================
// Application Security Groups (ASGs) — Logical workload-tier identifiers
// AZ-104 Domain: Networking — modern micro-segmentation pattern
// ============================================================================
// AZ-104 Context: ASGs let you write NSG rules against logical workload labels
// (e.g. "all web servers") instead of hard-coded subnet CIDRs. Rules become
// portable: when a VM moves to a new subnet, its ASG membership keeps the
// security posture intact. Multiple ASGs can be assigned to the same NIC, and
// a single ASG can span multiple subnets — useful for cross-tier patterns
// like a shared "monitoring agents" group spanning web + app + management VMs.
//
// Cost: ASGs are FREE — they are an ARM-only construct with no compute or
// storage backing them.
//
// This module deploys 3 ASGs (web, app, management) that are then referenced
// from spoke-network.bicep NSG rules to demonstrate ASG-based security.

// -- Parameters --------------------------------------------------------------

// Azure region — ASGs are regional resources but inexpensive to deploy in
// each region where they're referenced.
param location string

// Deployment environment (dev / staging / prod) — embedded into ASG names so
// dev and prod ASGs can coexist in the same subscription without collision.
param environment string

// Short organisation prefix used in CAF-style naming — keeps ASG names
// consistent with NSGs, route tables, and other networking resources.
param orgPrefix string

// Standard tag object inherited from main.bicep (Environment, ManagedBy,
// Project, CostCenter, DeployedOn). Applied to every ASG for cost attribution.
param tags object

// ── Web Tier ASG ───────────────────────────────────────────────────────────
// Logical group for all web-facing VMs (VMSS web instances, future bastion
// jumphosts that serve as web relays). NSG rules reference this ASG when
// allowing inbound HTTP/HTTPS or as the source for app-tier ingress rules.

resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  // Naming pattern: <orgPrefix>-asg-<tier>-<environment>
  // Mirrors the NSG/VNet naming convention so the relationship is obvious.
  name: '${orgPrefix}-asg-web-${environment}'
  location: location
  tags: tags
  // ASGs have no configurable properties — they are pure logical identifiers.
  // Membership is established by referencing the ASG ID from a NIC's ipConfig
  // applicationSecurityGroups array (set on VMSS NIC profile or standalone NIC).
  properties: {}
}

// ── App Tier ASG ───────────────────────────────────────────────────────────
// Logical group for middle-tier app server VMs. Used as the destination
// reference in NSG rules that permit web→app traffic on application ports
// (e.g. 8080, 8443) so the rule survives subnet topology changes.

resource asgApp 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-asg-app-${environment}'
  location: location
  tags: tags
  properties: {}
}

// ── Management ASG ─────────────────────────────────────────────────────────
// Logical group for management/jumphost workloads. Used in NSG rules that
// permit SSH/RDP from Bastion or admin networks. Decouples the rule from
// any specific subnet so management VMs can be placed in any subnet.

resource asgMgmt 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: '${orgPrefix}-asg-mgmt-${environment}'
  location: location
  tags: tags
  properties: {}
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Resource IDs are consumed by NSG rule definitions in spoke-network.bicep
// (sourceApplicationSecurityGroups / destinationApplicationSecurityGroups
// arrays) and by VMSS NIC configurations to associate VMs with the ASG.

// Web ASG ID — referenced as the destination on web-tier NSG rules and as
// the source on app-tier rules that permit web→app traffic.
output asgWebId string = asgWeb.id

// App ASG ID — referenced as the destination on app-tier NSG rules.
output asgAppId string = asgApp.id

// Management ASG ID — referenced as the destination on rules permitting
// administrative access (SSH/RDP from Bastion subnet).
output asgMgmtId string = asgMgmt.id

// Friendly names exposed for use in scripts / tags / documentation that
// need to look up ASGs by name rather than ID.
output asgWebName string = asgWeb.name
output asgAppName string = asgApp.name
output asgMgmtName string = asgMgmt.name
