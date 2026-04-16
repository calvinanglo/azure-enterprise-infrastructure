#Requires -Version 7.0
<#
.SYNOPSIS
    Network Watcher troubleshooting — IP flow verify, next hop, topology,
    connection troubleshoot, effective routes/NSG. AZ-104 networking deep-dive.

.PARAMETER Environment
    Target environment.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'

# Resource group names must match the pattern used in main.bicep.
# rgNet contains VNets, NSGs, and Network Watcher topology data.
# rgCompute contains the VMSS instances whose NICs are inspected.
$rgNet = "ent-rg-networking-$Environment"
$rgCompute = "ent-rg-compute-$Environment"

# Network Watcher is an Azure service that provides network diagnostic and
# monitoring capabilities. AZ-104: Network Watcher is auto-provisioned per
# region when a VNet is created, and it lives in the automatically created
# 'NetworkWatcherRG' resource group. The watcher name follows the pattern:
# NetworkWatcher_<region>. You can also create it manually if auto-provisioning
# is disabled (common in locked-down enterprise subscriptions).
$nwName = "NetworkWatcher_eastus2"
$nwRg = "NetworkWatcherRG"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Network Troubleshooting Toolkit"         -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. Network Topology ──────────────────────────────────────────────────
# AZ-104: The Network Watcher topology tool generates a visual/JSON map of
# all network resources in a resource group and their relationships —
# VNets, subnets, NICs, NSGs, public IPs, load balancers, and VNet peerings.
# This is the first step in diagnosing a misconfigured network: confirm the
# expected topology matches what is actually deployed.
# Portal path: Network Watcher > Topology > select subscription/RG.
# The CLI command returns a JSON list of resources and their associations,
# which can be used for automated topology drift detection.

Write-Host "[1/7] Generating network topology..." -ForegroundColor Yellow
az network watcher show-topology `
    --resource-group $rgNet `
    # Project name and ARM resource ID for each resource in the topology.
    # The full topology JSON also contains 'associations' showing parent-child
    # relationships (e.g., NIC → subnet, NSG → subnet).
    --query "resources[].{Name:name, Type:id}" `
    --output table
Write-Host "  Portal: Network Watcher > Topology > Select $rgNet" -ForegroundColor Gray

# ── 2. Effective NSG Rules ────────────────────────────────────────────────
# AZ-104: NSGs can be associated at two levels: subnet and NIC. When both
# are present, traffic must pass both NSG rule sets (subnet NSG first,
# then NIC NSG for inbound; NIC NSG first, then subnet NSG for outbound).
# The "effective security rules" view merges all applicable NSG rules into
# a single ordered list, showing the actual allow/deny decisions for each
# port/protocol. This is essential for diagnosing connectivity issues where
# the expected rule exists but another rule with a lower priority number
# (higher priority) is blocking traffic first.
# The 'az network nic list-effective-nsg' command retrieves this merged view.

Write-Host "`n[2/7] Checking effective NSG rules on web VMSS instance..." -ForegroundColor Yellow

# Retrieve the first VMSS instance's network profile to get the NIC resource ID.
# VMSS instances have auto-generated NIC IDs that include the instance number.
# AZ-104: VMSS NICs are not standalone resources — they are managed by the
# scale set and cannot be detached. Their effective NSG rules are inspected
# via the NIC ID extracted from the instance's networkProfile.
$vmssInstances = az vmss list-instances -g $rgCompute -n "ent-vmss-web-$Environment" --query "[0]" -o json 2>$null | ConvertFrom-Json
if ($vmssInstances) {
    # Extract the first NIC's resource ID from the instance's network profile.
    # Multiple NICs are possible (multi-NIC VMs) — [0] gets the primary NIC.
    $nicId = $vmssInstances.networkProfile.networkInterfaces[0].id
    Write-Host "  Instance NIC: $nicId" -ForegroundColor Gray
    # Display the command to run — the full output is large (all merged NSG
    # rules) and is better run interactively for inspection.
    Write-Host "  Run: az network nic list-effective-nsg --ids '$nicId'" -ForegroundColor White
} else {
    Write-Host "  No VMSS instances found — deploy compute first" -ForegroundColor DarkYellow
}

# ── 3. Effective Routes ─────────────────────────────────────────────────
# AZ-104: Route tables (UDRs) direct traffic between subnets, to the internet,
# or to virtual appliances (e.g., Azure Firewall). Like NSGs, routes can be
# applied at the subnet level. The "effective routes" view merges system routes
# (auto-created by Azure), VNet peering routes, and UDR routes into a single
# table showing the actual next-hop for each destination prefix.
# In this hub-spoke architecture, the expected default route (0.0.0.0/0)
# should point to the Azure Firewall private IP (VirtualAppliance next-hop type),
# indicating that all internet-bound traffic is being forced through the Firewall.
# If this route is missing, VMs would bypass the Firewall and route directly
# to the internet — a significant security gap.

Write-Host "`n[3/7] Checking effective routes..." -ForegroundColor Yellow
if ($vmssInstances) {
    Write-Host "  Run: az network nic show-effective-route-table --ids '$nicId'" -ForegroundColor White
    # Expected output: a row with addressPrefix=0.0.0.0/0, nextHopType=VirtualAppliance,
    # and nextHopIpAddress=<Firewall private IP>. This confirms forced tunneling is active.
    Write-Host "  Expected: 0.0.0.0/0 → VirtualAppliance (Firewall IP)" -ForegroundColor Gray
} else {
    Write-Host "  Skipped — no VMSS instances" -ForegroundColor DarkYellow
}

# ── 4. IP Flow Verify ───────────────────────────────────────────────────
# AZ-104: IP Flow Verify is a Network Watcher diagnostic tool that checks
# whether a specific 5-tuple (source IP, source port, destination IP,
# destination port, protocol) is allowed or denied by the effective NSG rules
# on a VM's NIC. It also identifies which specific NSG rule made the decision.
# This is the fastest way to answer the question: "Why can't VM A talk to VM B
# on port X?" — it simulates the traffic and shows the matching NSG rule name.
# The two test cases below cover the core hub-spoke security scenarios:
#   Test A: Web tier → App tier (should be ALLOWED by 'Allow-From-Web-Tier' rule)
#   Test B: Internet → App tier directly (should be DENIED — app tier is not
#           directly exposed; all inbound must go through the web LB)

Write-Host "`n[4/7] IP Flow Verify — test if traffic is allowed/denied..." -ForegroundColor Yellow

Write-Host "  Test: Can web tier reach app tier on port 8080?" -ForegroundColor Gray
Write-Host "  az network watcher test-ip-flow \" -ForegroundColor White
# --direction: Outbound tests whether the source VM can SEND traffic.
# Inbound tests whether the VM can RECEIVE traffic from the remote address.
Write-Host "    --direction Outbound \" -ForegroundColor White
Write-Host "    --protocol TCP \" -ForegroundColor White
# --local: the NIC's private IP + wildcard source port (any ephemeral port).
Write-Host "    --local 10.1.1.4:* \" -ForegroundColor White
# --remote: destination IP (app tier) + destination port (app service port).
Write-Host "    --remote 10.2.1.4:8080 \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
# The NSG rule 'Allow-From-Web-Tier' should explicitly permit this traffic.
# If the result is Deny, the NSG rule either has a typo, wrong priority, or
# the source IP range does not include the web subnet CIDR.
Write-Host "  Expected: Access=Allow (matched by 'Allow-From-Web-Tier' NSG rule)" -ForegroundColor Gray

Write-Host "`n  Test: Can internet reach app tier directly?" -ForegroundColor Gray
Write-Host "  az network watcher test-ip-flow \" -ForegroundColor White
Write-Host "    --direction Inbound \" -ForegroundColor White
Write-Host "    --protocol TCP \" -ForegroundColor White
Write-Host "    --local 10.2.1.4:8080 \" -ForegroundColor White
# 203.0.113.0/24 is the RFC 5737 documentation range — a safe public IP
# range to use in test scenarios (it is not routed on the internet).
Write-Host "    --remote 203.0.113.50:* \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
# 'Deny-All-Inbound' is the expected blocking rule — the app subnet NSG
# should have a default-deny rule for all non-web-tier inbound traffic.
Write-Host "  Expected: Access=Deny (matched by 'Deny-All-Inbound' NSG rule)" -ForegroundColor Gray

# ── 5. Next Hop ─────────────────────────────────────────────────────────
# AZ-104: The Next Hop tool shows what the next routing step is for traffic
# leaving a specific VM toward a specific destination IP. It queries the
# effective routing table (UDR + system routes + BGP routes) and returns:
#   - NextHopType: Internet, VirtualAppliance, VnetLocal, VirtualNetworkGateway, None
#   - NextHopIpAddress: the IP of the next hop (for VirtualAppliance type)
# In this architecture, traffic from the web tier to 8.8.8.8 (internet)
# should route through the Azure Firewall (VirtualAppliance) rather than
# going directly to the internet. If the next hop is 'Internet', it means
# the UDR forcing traffic through the Firewall is missing or misconfigured.

Write-Host "`n[5/7] Next Hop — verify traffic routing..." -ForegroundColor Yellow

Write-Host "  Test: Where does 10.1.1.4 → 8.8.8.8 go?" -ForegroundColor Gray
Write-Host "  az network watcher show-next-hop \" -ForegroundColor White
# --source-ip: the private IP of the web VMSS instance NIC.
Write-Host "    --source-ip 10.1.1.4 \" -ForegroundColor White
# --dest-ip: a public internet IP. 8.8.8.8 (Google DNS) is commonly used
# as a test destination to verify general internet reachability routing.
Write-Host "    --dest-ip 8.8.8.8 \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --resource-group $rgCompute \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
# Expected: NextHopType=VirtualAppliance with the Firewall's private IP.
# 10.0.1.4 is the typical private IP of Azure Firewall in the hub VNet's
# AzureFirewallSubnet — verify the actual IP from hub-network module outputs.
Write-Host "  Expected: NextHopType=VirtualAppliance, NextHopIp=10.0.1.4 (Firewall)" -ForegroundColor Gray

# ── 6. Connection Troubleshoot ──────────────────────────────────────────
# AZ-104: Connection Troubleshoot performs an end-to-end connectivity test
# from a source VM to a destination (IP or FQDN) on a specific port. Unlike
# IP Flow Verify (which only checks NSG rules), Connection Troubleshoot also
# checks routing, the VM agent status, and whether the destination port is
# actually listening. It installs the Network Watcher extension on the VM if
# not already present, so the first run may take a few minutes.
# Result: ConnectionStatus=Reachable (success) or Unreachable with hops showing
# where the connection failed (useful for multi-hop path debugging).

Write-Host "`n[6/7] Connection Troubleshoot — end-to-end connectivity test..." -ForegroundColor Yellow

Write-Host "  az network watcher test-connectivity \" -ForegroundColor White
# Source is a VMSS instance in the web tier.
Write-Host "    --source-resource <WEB_VMSS_INSTANCE_ID> \" -ForegroundColor White
# Destination is an app-tier instance private IP on the app service port.
Write-Host "    --dest-address 10.2.1.4 \" -ForegroundColor White
Write-Host "    --dest-port 8080 \" -ForegroundColor White
Write-Host "    --resource-group $rgCompute" -ForegroundColor White
# Reachable = the TCP connection succeeded end-to-end. If Unreachable, the
# output includes a 'hops' array showing each routing hop and where the
# connection was dropped, making this more informative than IP Flow Verify.
Write-Host "  Expected: ConnectionStatus=Reachable" -ForegroundColor Gray

# ── 7. NSG Flow Log Status ─────────────────────────────────────────────
# AZ-104: NSG flow logs record information about IP traffic flowing through
# NSGs — source/destination IP, port, protocol, and whether the traffic was
# allowed or denied. Flow logs are written to a storage account in JSON format
# and can optionally be analyzed in real time with Traffic Analytics (requires
# Log Analytics workspace). Flow logs are essential for security audits,
# compliance reporting, and post-incident forensics.
# AZ-104 exam tip: Know that NSG flow logs are enabled per NSG (not per rule),
# stored in a storage account, and have a configurable retention period.
# Traffic Analytics provides aggregated views in Log Analytics via queries.

Write-Host "`n[7/7] NSG Flow Log status..." -ForegroundColor Yellow

# List all flow logs in the region that belong to this deployment (filtered
# by name containing 'ent'). The query surfaces the key configuration fields:
#   - Enabled: whether the flow log is actively capturing traffic.
#   - RetentionDays: how long raw flow log JSON is kept in the storage account.
#   - TrafficAnalytics: whether real-time analysis is enabled in Log Analytics.
$flowLogs = az network watcher flow-log list --location eastus2 --query "[?contains(name,'ent')].{Name:name, Enabled:enabled, RetentionDays:retentionPolicy.days, TrafficAnalytics:flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled}" --output table 2>$null
if ($flowLogs) {
    Write-Host $flowLogs
} else {
    Write-Host "  No flow logs found — deploy network-watcher module first" -ForegroundColor DarkYellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Troubleshooting Reference Complete"      -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# Quick reference for portal navigation. AZ-104: The exam tests knowledge of
# where these tools live in the Azure Portal — memorize these paths.
Write-Host "Portal Verification Paths:" -ForegroundColor Cyan
Write-Host "  Topology       : Network Watcher > Topology" -ForegroundColor Gray
Write-Host "  IP Flow Verify : Network Watcher > IP flow verify" -ForegroundColor Gray
Write-Host "  Next Hop       : Network Watcher > Next hop" -ForegroundColor Gray
Write-Host "  Connection     : Network Watcher > Connection troubleshoot" -ForegroundColor Gray
Write-Host "  NSG Flow Logs  : Network Watcher > NSG flow logs" -ForegroundColor Gray
Write-Host "  Effective Rules: VM NIC > Effective security rules" -ForegroundColor Gray
Write-Host "  Effective Routes: VM NIC > Effective routes`n" -ForegroundColor Gray
