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

$rgNet = "ent-rg-networking-$Environment"
$rgCompute = "ent-rg-compute-$Environment"
$nwName = "NetworkWatcher_eastus2"
$nwRg = "NetworkWatcherRG"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Network Troubleshooting Toolkit"         -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. Network Topology ──────────────────────────────────────────────────

Write-Host "[1/7] Generating network topology..." -ForegroundColor Yellow
az network watcher show-topology `
    --resource-group $rgNet `
    --query "resources[].{Name:name, Type:id}" `
    --output table
Write-Host "  Portal: Network Watcher > Topology > Select $rgNet" -ForegroundColor Gray

# ── 2. Effective NSG Rules ────────────────────────────────────────────────

Write-Host "`n[2/7] Checking effective NSG rules on web VMSS instance..." -ForegroundColor Yellow

$vmssInstances = az vmss list-instances -g $rgCompute -n "ent-vmss-web-$Environment" --query "[0]" -o json 2>$null | ConvertFrom-Json
if ($vmssInstances) {
    $nicId = $vmssInstances.networkProfile.networkInterfaces[0].id
    Write-Host "  Instance NIC: $nicId" -ForegroundColor Gray
    Write-Host "  Run: az network nic list-effective-nsg --ids '$nicId'" -ForegroundColor White
} else {
    Write-Host "  No VMSS instances found — deploy compute first" -ForegroundColor DarkYellow
}

# ── 3. Effective Routes ─────────────────────────────────────────────────

Write-Host "`n[3/7] Checking effective routes..." -ForegroundColor Yellow
if ($vmssInstances) {
    Write-Host "  Run: az network nic show-effective-route-table --ids '$nicId'" -ForegroundColor White
    Write-Host "  Expected: 0.0.0.0/0 → VirtualAppliance (Firewall IP)" -ForegroundColor Gray
} else {
    Write-Host "  Skipped — no VMSS instances" -ForegroundColor DarkYellow
}

# ── 4. IP Flow Verify ───────────────────────────────────────────────────

Write-Host "`n[4/7] IP Flow Verify — test if traffic is allowed/denied..." -ForegroundColor Yellow

Write-Host "  Test: Can web tier reach app tier on port 8080?" -ForegroundColor Gray
Write-Host "  az network watcher test-ip-flow \" -ForegroundColor White
Write-Host "    --direction Outbound \" -ForegroundColor White
Write-Host "    --protocol TCP \" -ForegroundColor White
Write-Host "    --local 10.1.1.4:* \" -ForegroundColor White
Write-Host "    --remote 10.2.1.4:8080 \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
Write-Host "  Expected: Access=Allow (matched by 'Allow-From-Web-Tier' NSG rule)" -ForegroundColor Gray

Write-Host "`n  Test: Can internet reach app tier directly?" -ForegroundColor Gray
Write-Host "  az network watcher test-ip-flow \" -ForegroundColor White
Write-Host "    --direction Inbound \" -ForegroundColor White
Write-Host "    --protocol TCP \" -ForegroundColor White
Write-Host "    --local 10.2.1.4:8080 \" -ForegroundColor White
Write-Host "    --remote 203.0.113.50:* \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
Write-Host "  Expected: Access=Deny (matched by 'Deny-All-Inbound' NSG rule)" -ForegroundColor Gray

# ── 5. Next Hop ─────────────────────────────────────────────────────────

Write-Host "`n[5/7] Next Hop — verify traffic routing..." -ForegroundColor Yellow

Write-Host "  Test: Where does 10.1.1.4 → 8.8.8.8 go?" -ForegroundColor Gray
Write-Host "  az network watcher show-next-hop \" -ForegroundColor White
Write-Host "    --source-ip 10.1.1.4 \" -ForegroundColor White
Write-Host "    --dest-ip 8.8.8.8 \" -ForegroundColor White
Write-Host "    --vm <VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --resource-group $rgCompute \" -ForegroundColor White
Write-Host "    --nic <NIC_NAME>" -ForegroundColor White
Write-Host "  Expected: NextHopType=VirtualAppliance, NextHopIp=10.0.1.4 (Firewall)" -ForegroundColor Gray

# ── 6. Connection Troubleshoot ──────────────────────────────────────────

Write-Host "`n[6/7] Connection Troubleshoot — end-to-end connectivity test..." -ForegroundColor Yellow

Write-Host "  az network watcher test-connectivity \" -ForegroundColor White
Write-Host "    --source-resource <WEB_VMSS_INSTANCE_ID> \" -ForegroundColor White
Write-Host "    --dest-address 10.2.1.4 \" -ForegroundColor White
Write-Host "    --dest-port 8080 \" -ForegroundColor White
Write-Host "    --resource-group $rgCompute" -ForegroundColor White
Write-Host "  Expected: ConnectionStatus=Reachable" -ForegroundColor Gray

# ── 7. NSG Flow Log Status ─────────────────────────────────────────────

Write-Host "`n[7/7] NSG Flow Log status..." -ForegroundColor Yellow

$flowLogs = az network watcher flow-log list --location eastus2 --query "[?contains(name,'ent')].{Name:name, Enabled:enabled, RetentionDays:retentionPolicy.days, TrafficAnalytics:flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled}" --output table 2>$null
if ($flowLogs) {
    Write-Host $flowLogs
} else {
    Write-Host "  No flow logs found — deploy network-watcher module first" -ForegroundColor DarkYellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Troubleshooting Reference Complete"      -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Portal Verification Paths:" -ForegroundColor Cyan
Write-Host "  Topology       : Network Watcher > Topology" -ForegroundColor Gray
Write-Host "  IP Flow Verify : Network Watcher > IP flow verify" -ForegroundColor Gray
Write-Host "  Next Hop       : Network Watcher > Next hop" -ForegroundColor Gray
Write-Host "  Connection     : Network Watcher > Connection troubleshoot" -ForegroundColor Gray
Write-Host "  NSG Flow Logs  : Network Watcher > NSG flow logs" -ForegroundColor Gray
Write-Host "  Effective Rules: VM NIC > Effective security rules" -ForegroundColor Gray
Write-Host "  Effective Routes: VM NIC > Effective routes`n" -ForegroundColor Gray
