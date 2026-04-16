// ============================================================================
// Network Watcher — NSG flow logs, connection monitor, IP flow verify setup
// AZ-104 Domain: Configure and manage virtual networking
// Network Watcher is a regional service (one instance per region per subscription)
// that provides network monitoring, diagnostics, and logging capabilities.
// NSG flow logs capture information about IP traffic traversing NSGs — essential
// for security analysis, compliance auditing, and traffic pattern investigation.
// Traffic Analytics (built on Log Analytics) visualizes flow log data.
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region for the Network Watcher resource and all flow log resources.
// Flow logs must be in the same region as the NSGs they monitor.
param location string

// Deployment environment (dev / staging / prod) — drives flow log retention periods
param environment string

// Short organization prefix used in flow log resource names
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// Resource ID of the Log Analytics Workspace that receives Traffic Analytics data;
// Traffic Analytics processes flow logs and provides topology views and anomaly
// detection on top of raw NSG flow log data
param logAnalyticsWorkspaceId string

// ARM resource ID of the Web-tier NSG (applied to the web subnet); flow logs
// capture all traffic allowed or denied by this NSG
param webNsgId string

// ARM resource ID of the App-tier NSG (applied to the app subnet); flow logs
// capture east-west traffic between application tiers
param appNsgId string

// ARM resource ID of the Storage Account used to store raw NSG flow log JSON files.
// Flow logs are stored as block blobs in a container named 'insights-logs-networksecuritygroupflowevent'.
// The storage account must be in the same region as the NSG.
param storageAccountId string

// ── Network Watcher (auto-created per region, but we ensure it exists) ────
// Azure automatically creates a Network Watcher in 'NetworkWatcherRG' when
// certain operations occur, but explicitly declaring it here ensures it exists
// before the flow log resources that depend on it are created, and allows
// tagging for governance purposes.

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' = {
  // Naming convention matches Azure's auto-created format: NetworkWatcher_<region>
  // Using the same name avoids conflicts with the auto-created instance
  name: 'NetworkWatcher_${location}'
  // Network Watcher must be in the same region as the resources it monitors
  location: location
  tags: tags
}

// ── NSG Flow Logs: Web Tier ───────────────────────────────────────────────
// NSG flow logs record a 5-tuple for every network flow processed by the NSG:
// Source IP, Destination IP, Source port, Destination port, Protocol (TCP/UDP).
// Version 2 (used here) also records bytes and packets per flow — useful for
// identifying bandwidth-intensive sources and detecting data exfiltration.

resource webFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  // parent links this flow log to the Network Watcher resource above;
  // flow logs are child resources of Network Watcher
  parent: networkWatcher
  // Descriptive name identifies which NSG this flow log monitors
  name: '${orgPrefix}-flowlog-web-${environment}'
  // Flow log resource must be in the same region as the NSG being monitored
  location: location
  tags: tags
  properties: {
    // targetResourceId specifies which NSG's traffic to capture.
    // The NSG must already exist before this flow log is created.
    targetResourceId: webNsgId
    // storageId: ARM resource ID of the storage account where raw flow log JSON
    // files are written. Azure writes one JSON file per hour per NSG MAC address.
    storageId: storageAccountId
    // enabled: true activates flow log collection; set to false to pause logging
    // without deleting the flow log configuration
    enabled: true
    format: {
      // type: 'JSON' is the only supported format; flow log files are gzipped JSON
      type: 'JSON'
      // version 2 includes byte and packet counts per flow tuple, in addition to
      // the version 1 allow/deny decision. Version 2 is required for Traffic Analytics.
      version: 2
    }
    retentionPolicy: {
      // enabled: true activates automatic deletion of flow log blobs older than
      // the specified number of days from the storage account
      enabled: true
      // Prod: 90-day retention satisfies most compliance frameworks (SOC2, PCI-DSS).
      // Non-prod: 30 days sufficient for troubleshooting and cost management.
      days: environment == 'prod' ? 90 : 30
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        // enabled: true activates Traffic Analytics, which ingests flow log data
        // into Log Analytics and provides pre-built workbooks, topology maps,
        // and anomaly detection (e.g. malicious IP detection, geo-distribution)
        enabled: true
        // workspaceResourceId: ARM resource ID of the Log Analytics workspace
        // where Traffic Analytics publishes its processed data tables
        // (AzureNetworkAnalytics_CL)
        workspaceResourceId: logAnalyticsWorkspaceId
        // trafficAnalyticsInterval: how often (in minutes) Traffic Analytics
        // processes and aggregates the raw flow log data.
        // 10-minute interval provides near-real-time visibility; 60-minute
        // interval reduces Log Analytics ingestion cost but delays anomaly detection
        trafficAnalyticsInterval: 10
      }
    }
  }
}

// ── NSG Flow Logs: App Tier ───────────────────────────────────────────────
// Separate flow log for the application-tier NSG. Monitoring east-west traffic
// (between web tier and app tier subnets) is important for detecting lateral
// movement and verifying that micro-segmentation rules are working as intended.
// East-west flows are often missed when only monitoring perimeter NSGs.

resource appFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  parent: networkWatcher
  // Separate name from web flow log to distinguish the NSG being monitored
  name: '${orgPrefix}-flowlog-app-${environment}'
  location: location
  tags: tags
  properties: {
    // targetResourceId points to the app-tier NSG (not the web-tier NSG above)
    targetResourceId: appNsgId
    // Same storage account as the web tier flow log; flow log files are stored
    // in separate paths per NSG within the same container
    storageId: storageAccountId
    // enabled: true activates flow log collection for the app-tier NSG
    enabled: true
    format: {
      // Version 2 for byte/packet counts — required for Traffic Analytics
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      enabled: true
      // Same environment-based retention as the web tier flow log for consistency
      days: environment == 'prod' ? 90 : 30
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        // Traffic Analytics enabled for app tier — allows visualization of
        // inter-tier communication patterns in the Log Analytics workbooks
        enabled: true
        // Same Log Analytics workspace as the web tier for unified dashboards
        workspaceResourceId: logAnalyticsWorkspaceId
        // 10-minute processing interval matches the web tier configuration for
        // consistent near-real-time analysis across both NSG scopes
        trafficAnalyticsInterval: 10
      }
    }
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

// Short name of the Network Watcher; used in CLI diagnostic commands such as
// 'az network watcher packet-capture create' and 'az network watcher show-topology'
output networkWatcherName string = networkWatcher.name

// ARM resource ID of the web-tier NSG flow log; used in automation scripts
// that query flow log status or update retention/analytics configuration
output webFlowLogId string = webFlowLog.id

// ARM resource ID of the app-tier NSG flow log; used in automation and
// monitoring runbooks that verify flow log health across all NSG scopes
output appFlowLogId string = appFlowLog.id
