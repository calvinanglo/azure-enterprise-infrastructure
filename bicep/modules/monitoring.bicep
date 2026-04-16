// ============================================================================
// Monitoring — Log Analytics, alerts, action groups, dashboard
//
// AZ-104 Context: Azure Monitor is the unified observability platform for
// Azure resources. This module provisions the core monitoring stack:
//   1. Log Analytics Workspace  — centralised log/metric store (Azure Monitor Logs)
//   2. Action Group             — who to notify and how when an alert fires
//   3. Metric Alerts            — near-real-time threshold-based alerts on platform metrics
//   4. Scheduled Query Rule     — KQL-based log alerts for security/flow events
//   5. VM Insights Solution     — enables VM performance + dependency map via Azure Monitor
//
// AZ-104 exam domains covered here: Monitor and back up Azure resources (15-20%)
// ============================================================================

// ── Parameters ────────────────────────────────────────────────────────────────
// Parameters are values injected at deployment time, allowing the same module
// to be reused across environments without changing any code logic.

param location string
// location: Azure region for resources that are region-scoped (e.g. workspace,
// scheduled query rules). Alerts are deployed to 'global' because Azure Monitor
// metric alert processing is not region-bound.

param environment string
// environment: Distinguishes prod vs non-prod tiers. Used in:
//   - resource naming (avoids collisions across environments in the same subscription)
//   - conditional property values (retention, daily quota) so non-prod costs less

param orgPrefix string
// orgPrefix: Short organisation identifier prepended to every resource name.
// Follows the CAF (Cloud Adoption Framework) naming convention:
//   <orgPrefix>-<resource-abbreviation>-<environment>

param tags object
// tags: Key-value metadata applied to every resource.
// AZ-104: Tags are the primary mechanism for cost management (cost centre
// chargeback), environment filtering, and lifecycle automation (e.g. auto-
// shutdown policies targeting tag values).

// ── Log Analytics Workspace ────────────────────────────────────────────────
// AZ-104: A Log Analytics Workspace (LAW) is the foundational data store for
// Azure Monitor Logs. All diagnostic settings, VM agents (Azure Monitor Agent /
// MMA), and solutions forward data here. It provides KQL-based querying,
// alerting, and workbook visualisation. A single centralised workspace per
// environment is the recommended architecture for enterprise deployments to
// avoid data fragmentation and reduce cross-workspace query complexity.

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  // Resource type: Microsoft.OperationalInsights/workspaces
  // This is the ARM provider for Log Analytics Workspaces (part of Azure Monitor).

  name: '${orgPrefix}-law-${environment}'
  // Naming convention: <org>-law-<env>  ('law' = Log Analytics Workspace abbreviation)
  // Must be globally unique within a region; 4-63 chars, alphanumeric and hyphens.

  location: location
  // LAW is a region-scoped resource. Data sovereignty and latency requirements
  // typically drive this to the same region as the monitored resources.

  tags: tags
  // Apply the shared tag set. AZ-104: tagging here enables cost allocation to
  // this workspace's ingestion fees in Azure Cost Management.

  properties: {
    sku: {
      name: 'PerGB2018'
      // PerGB2018 is the modern pay-per-use pricing tier (replaces legacy node-
      // based tiers). Charges are based on GB ingested and GB retained beyond the
      // free 31-day retention window. This is the only SKU available for new
      // workspaces and is required to unlock features such as commitment tiers.
    }

    retentionInDays: environment == 'prod' ? 90 : 30
    // AZ-104: Retention controls how long log data is queryable 'hot' in the
    // workspace before it moves to long-term (cheap) archive storage.
    // - prod = 90 days: satisfies typical compliance/audit requirements and
    //   supports incident investigations that may span several months.
    // - non-prod = 30 days: reduces ingestion costs; historical depth is less
    //   critical in dev/test environments.
    // Default is 30 days; values beyond 90 days incur additional retention fees.

    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
      // AZ-104: This enforces the 'resource-context' access model.
      // When true, a user's ability to query logs is governed by their RBAC
      // permissions on the *source resource* (e.g. a VM), not on the workspace.
      // This is the least-privilege, zero-trust recommended setting for shared
      // enterprise workspaces — operators only see logs from resources they own.
      // Alternative (false) = workspace-context: anyone with Log Analytics Reader
      // on the workspace can read all logs, regardless of resource permissions.
    }

    workspaceCapping: {
      dailyQuotaGb: environment == 'prod' ? 10 : 5
      // AZ-104: The daily ingestion cap is a cost-control safety net.
      // Once the cap is hit, new data stops ingesting for the rest of the UTC day.
      // - prod = 10 GB/day: sized for a moderate enterprise workload; should be
      //   reviewed against actual volume and raised if alerting fires regularly.
      // - non-prod = 5 GB/day: keeps dev/test spend predictable.
      // Important: hitting the cap means gaps in monitoring — set an alert on the
      // 'Operation' table (OperationStatus == "Warning") to detect cap events.
    }
  }
}

// ── Action Group (email + webhook) ─────────────────────────────────────────
// AZ-104: An Action Group defines *what happens* when an alert fires — it is
// the notification and automation layer of Azure Monitor. It is separate from
// the alert rule itself so that many alert rules can share a single action group,
// making it easy to update on-call contact information in one place. Action groups
// support email, SMS, voice, Azure app push notifications, webhooks, ITSM
// connectors (ServiceNow, etc.), Azure Automation runbooks, Logic Apps, and
// Azure Functions.

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  // Resource type: Microsoft.Insights/actionGroups
  // Action groups are a sub-resource of Azure Monitor (Microsoft.Insights).

  name: '${orgPrefix}-ag-critical-${environment}'
  // Naming convention: <org>-ag-<severity-tier>-<env>
  // 'ag' = Action Group abbreviation. Having 'critical' in the name signals
  // this group is used for high-severity alerts, not informational ones.

  location: 'global'
  // Action Groups are a globally distributed, region-agnostic service.
  // 'global' must be specified — they are not deployed to a specific Azure region,
  // which ensures notifications are delivered even during a regional outage.

  tags: tags
  // Tags applied for cost attribution and governance filtering.

  properties: {
    groupShortName: 'CritAlert'
    // A short display name (max 12 chars) shown in SMS and email subjects so
    // recipients can immediately identify the source without reading the full
    // resource name. Keep it memorable and environment-neutral.

    enabled: true
    // Master enable/disable switch for the entire action group.
    // Setting to false suppresses all notifications without deleting the resource —
    // useful for planned maintenance windows to prevent alert storms.

    emailReceivers: [
      // emailReceivers: Array of email notification targets.
      // AZ-104: Email is the most common action type; combine with SMS for
      // on-call pages or with a webhook to forward into a ticketing system.
      {
        name: 'InfraTeam'
        // Logical label for this receiver — appears in alert notification payloads
        // and in the portal UI. Naming by team role (not individual) supports
        // rotation without changing IaC.

        emailAddress: 'infra-alerts@company.com'
        // Distribution list email address. Using a DL rather than individual
        // addresses means adding/removing people is an AD/email admin action,
        // not an infrastructure deployment.

        useCommonAlertSchema: true
        // AZ-104: The Common Alert Schema standardises the JSON payload format
        // across ALL alert types (metric, log, activity log, smart detection).
        // This means downstream webhook handlers, Logic Apps, and runbooks only
        // need to parse one schema. Strongly recommended for any new deployment.
        // Setting false uses the legacy per-alert-type schema format.
      }
    ]
  }
}

// ── Alert: High CPU on VMSS ────────────────────────────────────────────────
// AZ-104: Metric Alerts evaluate platform metrics emitted by Azure resources
// at near-real-time frequency (1–5 min). They do NOT require a Log Analytics
// Workspace — they read directly from the Azure Monitor metrics store. This
// makes them faster and cheaper to operate than log-based query alerts.
// This rule detects sustained CPU pressure on Virtual Machine Scale Sets,
// giving the operations team time to scale out before user impact occurs.

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  // Resource type: Microsoft.Insights/metricAlerts
  // The 2018-03-01 API version is the stable version that supports multi-resource
  // metric alerts targeting an entire subscription scope.

  name: '${orgPrefix}-alert-high-cpu-${environment}'
  // Naming convention: <org>-alert-<condition>-<env>. Descriptive names are
  // important because alert rule names appear in notification subjects.

  location: 'global'
  // Metric alert rules are globally processed by Azure Monitor — not
  // region-specific. Must always be 'global' for this resource type.

  tags: tags
  // Tags for governance. Useful for filtering "all alerts in prod" in the portal.

  properties: {
    severity: 2
    // AZ-104 Alert Severity Levels (0–4):
    //   0 = Critical   — service is down, immediate action required
    //   1 = Error       — significant degradation, action required soon
    //   2 = Warning     — elevated risk, investigate proactively  ← this alert
    //   3 = Informational — noteworthy but not immediately actionable
    //   4 = Verbose      — diagnostic/debug use only
    // CPU at 85% is a Warning: the system is stressed but still operational.
    // Severity does NOT control who is notified — that is the action group's job.
    // Severity controls visual priority in Azure Monitor > Alerts dashboards.

    enabled: true
    // Master toggle. Setting false disables evaluation without deleting the rule —
    // useful for suppression during known maintenance or load tests.

    scopes: [
      subscription().id
      // AZ-104: Scoping to the subscription ID combined with the
      // MultipleResourceMultipleMetricCriteria odata.type means this single alert
      // rule automatically covers ALL VMSS resources in the subscription, including
      // ones created after the alert rule was deployed. This is the recommended
      // approach vs creating per-resource alert rules, which require IaC changes
      // every time a new scale set is added.
    ]

    evaluationFrequency: 'PT5M'
    // ISO 8601 duration: how often Azure Monitor checks whether the threshold is
    // breached. PT5M = every 5 minutes.
    // Trade-off: more frequent = faster detection, slightly higher cost.
    // For CPU this is an appropriate balance — a 1-minute frequency adds cost
    // without meaningfully improving response time for a sustained CPU condition.

    windowSize: 'PT15M'
    // The time window over which the metric is aggregated before comparing to the
    // threshold. PT15M = 15-minute rolling window.
    // windowSize must be >= evaluationFrequency. Using a 15-minute window with
    // Average aggregation smooths out transient CPU spikes (e.g. a 30-second
    // backup task) and only alerts on *sustained* high CPU, reducing false
    // positives. Shorter windows (PT5M) would be more sensitive but noisier.

    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      // This odata.type selects the multi-resource criteria schema, which enables
      // one alert rule to monitor multiple resources (or all resources of a type
      // within the scope). The alternative 'SingleResourceMultipleMetricCriteria'
      // targets a single resource only and requires a separate rule per resource.

      allOf: [
        // allOf: ALL conditions listed must be true simultaneously to fire the alert.
        // (Use 'anyOf' if any one condition should be sufficient — not used here.)
        {
          name: 'HighCPU'
          // Internal name for this criterion within the alert rule. Must be unique
          // within the allOf/anyOf array. Used in alert payload to identify which
          // condition triggered the alert.

          criterionType: 'StaticThresholdCriterion'
          // StaticThresholdCriterion: compare the metric against a fixed numeric
          // threshold defined below. The alternative is 'DynamicThresholdCriterion'
          // which uses ML-based baselines — useful when a resource has variable
          // expected behaviour (e.g. different CPU patterns on weekday vs weekend).
          // Static is appropriate here because 85% CPU is universally high
          // regardless of time of day or historical pattern.

          metricName: 'Percentage CPU'
          // The exact platform metric name as published by the resource provider.
          // 'Percentage CPU' is a standard metric emitted by all Azure Compute
          // resources. Find valid metric names in: Azure Monitor > Metrics browser,
          // or the ARM REST API metrics definitions endpoint.

          metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
          // Narrows which resource type to evaluate within the scoped subscription.
          // Required when the scope is broad (subscription/resource group) so Azure
          // Monitor knows which resource provider's metric store to query.

          operator: 'GreaterThan'
          // Comparison operator applied as: metricValue [operator] threshold.
          // GreaterThan fires when CPU% > 85. Other options: GreaterThanOrEqual,
          // LessThan, LessThanOrEqual, Equals, NotEquals.

          threshold: 85
          // The numeric threshold value in the metric's native unit (% for CPU).
          // 85% is a common industry threshold for VMSS CPU warnings — high enough
          // to indicate real pressure but below the 90-95% level where request
          // queuing and latency degradation typically begins.

          timeAggregation: 'Average'
          // How individual data points within the windowSize are collapsed into
          // a single value for comparison. Options: Average, Minimum, Maximum,
          // Total, Count.
          // Average is correct for CPU% — it represents the mean utilisation
          // across all instances in the scale set over the 15-minute window.
          // Maximum would fire if even one brief spike occurred on one instance.
        }
      ]
    }

    actions: [
      // The list of action groups to invoke when this alert transitions to 'Fired'.
      // Multiple action groups can be listed (e.g. email team + create ITSM ticket).
      {
        actionGroupId: actionGroup.id
        // Reference to the Action Group resource defined earlier in this module.
        // Bicep resolves this to the full ARM resource ID at deployment time,
        // creating an implicit dependency so the action group is created first.
      }
    ]

    description: 'Fires when average CPU exceeds 85% over 15 minutes'
    // Human-readable description shown in the portal and included in alert
    // notification emails. Good descriptions answer: what fired, why it matters,
    // and what the responder should do (can be expanded with runbook links).
  }
}

// ── Alert: VM Availability < 100% ──────────────────────────────────────────
// AZ-104: VM Availability (VmAvailabilityMetric) is a binary health metric
// emitted by the Azure platform itself — it reflects the hypervisor's view of
// whether the VM is running (1) or unavailable due to host issues, OS crash,
// deallocated state, etc. (0). This alert is the highest-severity rule in this
// module because any drop below 1.0 means at least one instance in the scale
// set is not serving traffic, which can indicate an infrastructure failure.

resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${orgPrefix}-alert-vm-availability-${environment}'
  // Naming follows the same <org>-alert-<condition>-<env> convention. The name
  // clearly identifies the resource and its purpose in the portal and in alerts.

  location: 'global'
  // Metric alert rules are globally processed — region must always be 'global'.

  tags: tags
  // Shared tag set for governance, cost management, and lifecycle policies.

  properties: {
    severity: 1
    // Severity 1 = Error — this is one level below Critical (0).
    // An unavailable VM is serious (service impact likely) but not necessarily
    // a complete outage if the VMSS has multiple healthy instances. Severity 1
    // ensures this appears prominently in alert dashboards and triggers urgent
    // (but not immediate all-hands) response procedures.
    // Compare: the CPU alert above uses severity 2 (Warning) because high CPU
    // does not yet mean service degradation.

    enabled: true
    // Alert rule is active. Can be toggled false for maintenance without deletion.

    scopes: [
      subscription().id
      // Subscription-wide scope: all VMSS resources in this subscription are
      // covered automatically. This is the same approach as the CPU alert — one
      // rule covers the entire fleet, avoiding per-resource rule sprawl.
    ]

    evaluationFrequency: 'PT1M'
    // Evaluate every 1 minute — much more aggressive than the CPU alert (PT5M).
    // Availability is a binary, platform-reported metric; there is no need to
    // smooth it over longer periods. Fast evaluation means faster incident
    // detection and lower Mean Time To Detect (MTTD).

    windowSize: 'PT5M'
    // 5-minute aggregation window. Average over 5 minutes allows for a brief
    // transient dip (e.g. rolling upgrade briefly taking an instance offline)
    // without false-positiving. If a VM is truly unavailable for 5 consecutive
    // minutes, the average will be < 1 and the alert fires.
    // windowSize must be >= evaluationFrequency (5m >= 1m — satisfied).

    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      // Multi-resource criteria: same approach as cpuAlert. Allows subscription-
      // scoped monitoring of all VMSS resources with a single rule.

      allOf: [
        {
          name: 'VMAvailabilityDrop'
          // Internal criterion name. Descriptive names aid post-incident triage
          // when reviewing alert history and fired conditions.

          criterionType: 'StaticThresholdCriterion'
          // Static threshold is correct here: availability of 1.0 is an absolute
          // expectation, not a relative or baseline-dependent value. Dynamic
          // thresholds would be inappropriate for a binary metric.

          metricName: 'VmAvailabilityMetric'
          // Platform metric emitted by the Azure hypervisor fabric. Values:
          //   1 = VM is running and healthy from the platform perspective
          //   0 = VM is unavailable (stopped, deallocated, host issue, OS crash)
          // An Average < 1 means at least one instance in the scope is unhealthy.
          // This metric does not require any agent inside the VM — it is always
          // available as long as the VMSS resource exists.

          metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
          // Target resource type — filters to VMSS instances only within the
          // subscription scope. Required for multi-resource criteria.

          operator: 'LessThan'
          // Fire when average availability < threshold (1.0).
          // LessThan (not LessThanOrEqual) is used because the threshold is 1:
          // the metric must drop strictly below 1.0 to trigger.

          threshold: 1
          // 1 = 100% availability. Any value < 1 means at least one instance is
          // not running. In a VMSS with 3 instances, one unhealthy instance would
          // yield an average of ~0.67, well below this threshold.

          timeAggregation: 'Average'
          // Average across all instances and all data points in the window.
          // For a scale set, this aggregates availability across all member VMs,
          // so even a single failed instance in a large fleet will register.
        }
      ]
    }

    actions: [
      {
        actionGroupId: actionGroup.id
        // Trigger the shared critical action group (email to infra team).
        // The same action group is reused across alert rules — one place to update
        // notification targets, consistent with DRY infrastructure principles.
      }
    ]

    description: 'Fires when VM availability drops below 100%'
    // Description surfaced in notification emails and the portal alerts blade.
    // AZ-104 best practice: link to the relevant runbook URL in the description
    // so on-call engineers immediately know the response procedure.
  }
}

// ── Scheduled Query: NSG Deny Events ───────────────────────────────────────
// AZ-104: Scheduled Query Rules (Log Alerts) execute a KQL query against a
// Log Analytics Workspace on a defined schedule. Unlike Metric Alerts which
// read from the pre-aggregated metrics store, log alerts can query any data
// in the workspace — including custom logs, security events, and network flow
// data. This makes them essential for security-oriented alerting.
//
// This rule detects a spike in NSG-denied traffic — a potential indicator of:
//   - A port/brute-force scan against the environment
//   - A misconfigured application repeatedly hitting a blocked port
//   - DDoS traffic being blocked at the perimeter
// Prerequisite: NSG Flow Logs must be enabled and directed to this workspace
// via Network Watcher + Traffic Analytics, which populates AzureNetworkAnalytics_CL.

resource nsgDenyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  // Resource type: Microsoft.Insights/scheduledQueryRules
  // The 2023-03-15-preview API version is the current recommended version for
  // log alert rules. It supersedes the 2018-04-16 version which used a
  // different schema and lacked features like failingPeriods.

  name: '${orgPrefix}-alert-nsg-deny-spike-${environment}'
  // Naming: <org>-alert-<condition>-<env>. 'nsg-deny-spike' clearly describes
  // the security condition being monitored.

  location: location
  // Scheduled Query Rules ARE region-scoped (unlike metric alerts) because they
  // are associated with a specific Log Analytics Workspace in a region.
  // Must match the region of the workspace in scopes below.

  tags: tags
  // Tags for governance and cost attribution. Log alert rule evaluation costs
  // are billed per query execution, so tagging helps track monitoring costs.

  properties: {
    severity: 3
    // Severity 3 = Informational (but action-worthy).
    // NSG deny spikes are a security signal that warrants investigation but is
    // not itself a service outage. Teams should triage and decide whether it
    // represents a genuine attack or a configuration issue.
    // AZ-104: Severity should reflect urgency of response, not just impact.

    enabled: true
    // Rule is active and will run on its evaluationFrequency schedule.

    evaluationFrequency: 'PT10M'
    // Run the KQL query every 10 minutes. This is the polling interval —
    // how often Azure Monitor checks for new alert conditions.
    // Must be <= windowSize. 10 minutes balances detection speed against
    // query cost (each evaluation executes against the LAW and incurs cost).

    windowSize: 'PT30M'
    // The time range passed to the KQL query as the implicit filter.
    // The query will evaluate data from [now - 30 minutes] to [now].
    // 30 minutes provides enough historical context for the summarize
    // operator to produce meaningful counts, while the inner 'bin(10m)'
    // in the query groups events into 10-minute buckets for analysis.

    scopes: [
      logAnalytics.id
      // Scheduled Query Rules must be scoped to a Log Analytics Workspace
      // (or an Application Insights resource). This is the workspace defined
      // earlier in this module. Bicep's .id reference creates an implicit
      // dependency, ensuring the workspace is created before this alert rule.
      // Contrast with metric alerts scoped to subscription().id — log alerts
      // always need an explicit data source (the workspace).
    ]

    criteria: {
      allOf: [
        // allOf: all criteria in this array must be satisfied. A single KQL
        // criterion is used here — the query itself does the heavy lifting.
        {
          query: '''
            AzureNetworkAnalytics_CL
            // AzureNetworkAnalytics_CL: Custom log table populated by Azure
            // Network Watcher Traffic Analytics when NSG Flow Logs are enabled.
            // Each row represents a summarised network flow record including
            // source IP, destination, port, protocol, and flow status.

            | where FlowStatus_s == "D"
            // Filter to Denied flows only. FlowStatus_s values:
            //   "A" = Allowed by NSG rule
            //   "D" = Denied by NSG rule
            // We only care about denied traffic for this security alert.

            | summarize DenyCount = count() by bin(TimeGenerated, 10m), NSGRule_s
            // Group denied flow events into 10-minute time buckets and by the
            // specific NSG rule that triggered the deny.
            // bin(TimeGenerated, 10m): rounds timestamps down to the nearest
            // 10-minute boundary, creating discrete time buckets.
            // NSGRule_s: the name of the NSG rule responsible for the deny —
            // critical for the responder to know which rule and port is targeted.

            | where DenyCount > 100
            // Only surface time-bucket/rule combinations where the deny count
            // exceeds 100. This threshold filters out normal background noise
            // (misconfigured apps, occasional scan probes) and focuses on
            // genuine spikes that could indicate active reconnaissance or attack.
            // Tune this threshold based on baseline deny rates in the environment.
          '''

          timeAggregation: 'Count'
          // For log alert rules, timeAggregation specifies how to aggregate the
          // query result rows for comparison against the threshold.
          // 'Count' = count the number of rows returned by the query.
          // The query already filters to DenyCount > 100, so any returned row
          // represents a bucket with a spike. We just need to know if there are
          // any such rows (Count > 0 triggers the alert).

          operator: 'GreaterThan'
          // Alert fires when: [row count from query] GreaterThan [threshold=0]
          // i.e., fire if the query returns at least 1 row.
          // Combined with the query's WHERE DenyCount > 100 clause, this means:
          // fire if any 10-minute bucket has > 100 NSG denies for any single rule.

          threshold: 0
          // Threshold of 0: alert if the query returns MORE than 0 rows (i.e.,
          // any row at all). The actual volumetric threshold (>100 denies) is
          // enforced within the KQL query itself, keeping the logic readable.

          failingPeriods: {
            numberOfEvaluationPeriods: 1
            // Total number of consecutive evaluation periods to consider.
            // With 1 period, a single positive evaluation is enough to fire.
            // Increasing this (e.g. to 3) would require the condition to be
            // true across multiple evaluations before alerting — useful for
            // reducing alert fatigue on intermittent conditions.

            minFailingPeriodsToAlert: 1
            // Minimum number of the above periods that must be positive to fire.
            // 1 of 1: fire immediately on the first positive evaluation.
            // Together with numberOfEvaluationPeriods: 1, this means the alert
            // fires as soon as any single evaluation period finds a spike.
            // For a security signal like NSG denies, fast detection is preferred
            // over reducing false positives with multi-period confirmation.
          }
        }
      ]
    }

    actions: {
      actionGroups: [actionGroup.id]
      // Trigger the critical action group when this alert fires.
      // Note: scheduledQueryRules use 'actions.actionGroups' (an object with
      // an array property), while metricAlerts use 'actions' as a direct array.
      // This is a schema difference between the two alert resource types.
    }

    description: 'Fires when >100 NSG deny events occur in 10 minutes'
    // Description: concise summary of the alert condition. In production,
    // expand this to include: potential causes, severity rationale, and a
    // link to the incident response runbook for NSG deny spikes.
  }
}

// ── Log Analytics Solutions ────────────────────────────────────────────────
// AZ-104: Log Analytics Solutions (also called OMS Solutions or Management
// Solutions) are pre-packaged sets of views, saved queries, alerts, and data
// collection rules that extend the capabilities of a Log Analytics Workspace.
// They are installed by deploying a Microsoft.OperationsManagement/solutions
// resource linked to the workspace. This activates the solution's dashboards
// and enables the corresponding data collection.
//
// VM Insights (formerly known as Azure Monitor for VMs) provides:
//   - Performance charts: CPU, memory, disk, and network per VM and per process
//   - Map feature: visualises network connections between VMs and external deps
//   - Health model: aggregated health state based on performance thresholds
// VM Insights requires the Azure Monitor Agent (AMA) or the legacy Log Analytics
// Agent (MMA) to be installed on each VM, plus the Dependency Agent for the Map
// feature. These agents are typically deployed via VM Extensions in the compute
// module, not here — this resource only activates the solution on the workspace.

resource vmInsights 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  // Resource type: Microsoft.OperationsManagement/solutions
  // The 2015-11-01-preview API version is the only available version for this
  // resource type. Despite the 'preview' label, it has been stable for years
  // and is the required API version for all Log Analytics solution deployments.

  name: 'VMInsights(${logAnalytics.name})'
  // The name format 'SolutionName(WorkspaceName)' is REQUIRED by the
  // OperationsManagement provider — it is not a convention, it is enforced.
  // The workspace name is embedded in the solution resource name so that
  // the platform can associate the solution with the correct workspace at
  // the resource provider level.

  location: location
  // Solutions are region-scoped and must be deployed to the same region as
  // the Log Analytics Workspace they extend.

  tags: tags
  // Standard governance tags applied for consistency.

  plan: {
    // The 'plan' block is a top-level property (not under 'properties') unique
    // to OperationsManagement resources. It identifies the solution package
    // in the Azure Marketplace / OMS Gallery.

    name: 'VMInsights(${logAnalytics.name})'
    // plan.name must match the resource name exactly — both use the
    // 'SolutionName(WorkspaceName)' pattern.

    publisher: 'Microsoft'
    // The solution is published by Microsoft (first-party). Third-party
    // solutions would have a different publisher here (e.g. 'Palo Alto Networks').

    product: 'OMSGallery/VMInsights'
    // The OMS Gallery product identifier for VM Insights. This is the internal
    // catalogue slug that the resource provider uses to look up and install
    // the solution package. Format: 'OMSGallery/<SolutionName>'.
    // Other common solutions: 'OMSGallery/SecurityInsights' (Sentinel),
    // 'OMSGallery/Updates' (Update Management), 'OMSGallery/ChangeTracking'.

    promotionCode: ''
    // Required field; leave empty for standard (non-discounted) solutions.
    // Promotional codes are used for trial or partner-discounted offerings.
  }

  properties: {
    workspaceResourceId: logAnalytics.id
    // Links this solution to the specific Log Analytics Workspace by ARM
    // resource ID. This is what binds the solution's queries, views, and data
    // collection to this workspace instance. The Bicep .id reference creates
    // an implicit dependency — the workspace must be fully provisioned before
    // this solution resource is deployed.
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// AZ-104: Bicep outputs pass values from this module back to the parent
// template (main.bicep) or to other modules that depend on them.
// Outputs are the approved pattern for cross-module resource referencing —
// they avoid hard-coding resource IDs and keep modules loosely coupled.

output workspaceId string = logAnalytics.id
// workspaceId: The full ARM resource ID of the Log Analytics Workspace.
// Format: /subscriptions/<subId>/resourceGroups/<rg>/providers/
//         Microsoft.OperationalInsights/workspaces/<name>
// Consumed by: compute module (VM diagnostic settings point here),
// network module (NSG Flow Log destination), and any other module that
// needs to forward diagnostics to centralised logging.

output workspaceName string = logAnalytics.name
// workspaceName: The plain resource name of the workspace.
// Useful when a downstream resource needs only the name (not the full ID),
// e.g. constructing the VM Insights solution name in a child deployment,
// or when referencing the workspace in Azure CLI / PowerShell commands.

output actionGroupId string = actionGroup.id
// actionGroupId: The full ARM resource ID of the critical action group.
// Consumed by: any additional alert rules defined in other modules that
// should notify the same infra team. Centralising the action group ID as
// an output means all modules reference the same notification endpoint —
// no duplication, and updating contact details requires only one resource change.
