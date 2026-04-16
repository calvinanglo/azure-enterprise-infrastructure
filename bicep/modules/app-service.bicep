// ============================================================================
// App Service — Web App, App Service Plan, deployment slots, scaling, TLS
// AZ-104 Domain: Deploy and manage Azure compute resources
// App Service is Azure's PaaS (Platform as a Service) for web applications.
// The App Service Plan defines the compute resources (VM size, OS, scaling).
// Web Apps run on the plan and share its compute capacity.
// Deployment slots enable zero-downtime deployments via slot swaps.
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region where all App Service resources are deployed
param location string

// Deployment environment (dev / staging / prod) — drives SKU selection, slot
// creation, autoscale, and feature toggles throughout this module
param environment string

// Short organization prefix used in all resource names
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// Resource ID of the Log Analytics Workspace for diagnostic data collection
param logAnalyticsWorkspaceId string

// ARM resource ID of the VNet subnet delegated to App Service for VNet
// Integration; allows the web app to make outbound calls to private resources
// (VMs, databases, storage) without traversing the public internet
param appSubnetId string

// ── App Service Plan ──────────────────────────────────────────────────────
// The App Service Plan is the billing and compute unit. All apps on the same
// plan share its resources. SKU tier determines features: Basic (B1) lacks
// autoscale and deployment slots; Standard (S1) and above support both.

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  // Naming convention: <prefix>-asp-<environment>
  name: '${orgPrefix}-asp-${environment}'
  location: location
  tags: tags
  // 'linux' kind is required for Linux-based plans; paired with reserved: true below
  kind: 'linux'
  sku: {
    // S1 (Standard) for prod: supports deployment slots, autoscale, custom domains,
    // SSL certificates, and VNet integration.
    // B1 (Basic) for non-prod: sufficient for development; no slots or autoscale.
    name: environment == 'prod' ? 'S1' : 'B1'
    // Tier must match the SKU name: Standard for S1, Basic for B1
    tier: environment == 'prod' ? 'Standard' : 'Basic'
    // Initial instance count. Prod starts with 2 for high availability (no single point
    // of failure). Non-prod uses 1 to minimize cost.
    capacity: environment == 'prod' ? 2 : 1
  }
  properties: {
    // reserved: true is REQUIRED for Linux plans; sets the underlying host OS to Linux.
    // Without this, the plan defaults to Windows even if kind is 'linux'.
    reserved: true                             // Required for Linux
    // Zone redundancy distributes plan instances across Availability Zones (AZs)
    // within the region, providing resilience against datacenter-level failures.
    // Requires Standard or Premium SKU and a minimum of 3 instances.
    zoneRedundant: environment == 'prod'
  }
}

// ── Web App ───────────────────────────────────────────────────────────────
// A Web App is an App Service resource that runs application code. Multiple
// Web Apps can share a single App Service Plan.

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  // uniqueString() appended to guarantee globally unique app hostname.
  // App names become part of the default hostname: <name>.azurewebsites.net
  name: '${orgPrefix}-webapp-${environment}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  // 'app,linux' declares this as a Linux web application (not a function app or container)
  kind: 'app,linux'
  identity: {
    // SystemAssigned managed identity: Azure AD creates and manages a service
    // principal automatically tied to this web app's lifecycle. Used to
    // authenticate to Key Vault, Storage, and other Azure services without
    // storing credentials in app settings or connection strings.
    type: 'SystemAssigned'
  }
  properties: {
    // serverFarmId links this app to the App Service Plan above
    serverFarmId: appServicePlan.id
    // httpsOnly: true redirects all HTTP traffic to HTTPS at the platform level;
    // enforces TLS without requiring application-level redirect logic
    httpsOnly: true
    // VNet Integration: routes outbound traffic from the app through the specified
    // subnet into the VNet, enabling access to private resources (databases, VMs)
    // without public IP exposure. The subnet must be delegated to
    // Microsoft.Web/serverFarms.
    virtualNetworkSubnetId: appSubnetId
    siteConfig: {
      // Runtime stack: Node.js 20 LTS on Linux. Format: '<runtime>|<version>'.
      // This controls which language runtime Azure provisions on the host.
      linuxFxVersion: 'NODE|20-lts'
      // alwaysOn: true keeps the app worker process loaded even with zero requests,
      // eliminating cold-start delays. Requires Basic SKU or higher.
      // Disabled in non-prod to reduce compute cost during idle periods.
      alwaysOn: environment == 'prod'
      // ftpsState: 'Disabled' prevents FTP/FTPS deployments; all deployments must
      // use Kudu (SCM), ZIP deploy, or CI/CD pipelines — more secure and auditable
      ftpsState: 'Disabled'
      // minTlsVersion enforces a minimum TLS version for inbound connections.
      // TLS 1.2 is the current compliance baseline (TLS 1.0/1.1 are deprecated).
      minTlsVersion: '1.2'
      // http20Enabled enables HTTP/2 support, improving performance for modern
      // browsers via multiplexing and header compression
      http20Enabled: true
      // healthCheckPath: App Service probes this path every minute. If the path
      // returns non-200 responses, the instance is marked unhealthy and replaced.
      // Requires the application to expose a lightweight /health endpoint.
      healthCheckPath: '/health'
      appSettings: [
        {
          // Pins the Node.js version used by the App Service runtime shim.
          // ~20 means "latest patch of major version 20"
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
        {
          // Makes the current environment name available to application code
          // for environment-specific configuration (logging level, feature flags)
          name: 'ENVIRONMENT'
          value: environment
        }
      ]
    }
  }
}

// ── Deployment Slot: Staging ──────────────────────────────────────────────
// Deployment slots are live app environments within the same App Service Plan.
// The staging slot allows new code to warm up (connect to DBs, cache pre-warm,
// run health checks) before swapping into production with zero downtime.
// Slots only exist on Standard SKU and above; hence the prod-only condition.

resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = if (environment == 'prod') {
  // parent links this slot to the production web app above
  parent: webApp
  // 'staging' is the slot name; accessible at <appname>-staging.azurewebsites.net
  name: 'staging'
  location: location
  // Merge base tags with a Slot-specific tag to distinguish staging costs
  tags: union(tags, { Slot: 'staging' })
  kind: 'app,linux'
  identity: {
    // Staging slot gets its own system-assigned identity so it can independently
    // authenticate to Key Vault during warm-up before the swap
    type: 'SystemAssigned'
  }
  properties: {
    // Staging slot uses the same App Service Plan as production
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      // alwaysOn: true in staging ensures the slot is always warm and ready
      // to receive swapped traffic immediately without cold-start delay
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      // autoSwapSlotName: automatically swaps the staging slot into the named
      // target slot ('production') after a successful deployment and warm-up.
      // This enables fully automated blue-green deployments from the CI/CD pipeline.
      autoSwapSlotName: 'production'          // Auto-swap after warm-up
      appSettings: [
        {
          // Staging slot identifies itself as 'staging' so application code can
          // apply staging-specific behaviors (e.g. verbose logging, test flags)
          name: 'ENVIRONMENT'
          value: 'staging'
        }
      ]
    }
  }
}

// ── Autoscale: App Service ────────────────────────────────────────────────
// Autoscale adjusts the number of App Service Plan instances dynamically based
// on metric thresholds. Scale-out adds instances to handle load; scale-in
// removes them to reduce cost. Only deployed for prod (Standard SKU required).

resource appServiceAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if (environment == 'prod') {
  // Autoscale setting name — descriptive for portal identification
  name: '${orgPrefix}-autoscale-asp-${environment}'
  location: location
  tags: tags
  properties: {
    // enabled: true activates the autoscale engine; false keeps configuration
    // but stops automatic scaling (useful for maintenance windows)
    enabled: true
    // targetResourceUri links this autoscale setting to the App Service Plan;
    // the engine monitors the plan's aggregate metrics across all instances
    targetResourceUri: appServicePlan.id
    profiles: [
      {
        // 'DefaultProfile' is the baseline profile applied when no schedule-based
        // profiles are active. Additional profiles can be added for time-based
        // scaling (e.g. scale up during business hours, down overnight).
        name: 'DefaultProfile'
        capacity: {
          // minimum: the floor instance count; plan will never scale below 2
          // instances in prod to maintain high availability
          minimum: '2'
          // maximum: the ceiling instance count; caps cost and prevents runaway scaling
          maximum: '5'
          // default: instance count used when autoscale cannot read metrics
          // (e.g. during a metrics outage); matches minimum for safety
          default: '2'
        }
        rules: [
          {
            // Scale-OUT rule: add an instance when CPU is high
            metricTrigger: {
              // CpuPercentage is the aggregate CPU % across all plan instances
              metricName: 'CpuPercentage'
              // metricResourceUri scopes the metric to this specific App Service Plan
              metricResourceUri: appServicePlan.id
              // timeGrain: the resolution of raw metric data points (1-minute granularity)
              timeGrain: 'PT1M'
              // statistic: how individual instance metrics are combined ('Average'
              // = mean across all instances; alternatives: Min, Max, Sum)
              statistic: 'Average'
              // timeWindow: the evaluation window; autoscale looks back 5 minutes
              // of averaged data before deciding to scale
              timeWindow: 'PT5M'
              // timeAggregation: how data points within the window are aggregated
              timeAggregation: 'Average'
              // operator and threshold: trigger fires when 5-min average CPU > 70%
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              // 'Increase' = scale out (add instances)
              direction: 'Increase'
              // 'ChangeCount' adds/removes a fixed number of instances
              type: 'ChangeCount'
              // Add 1 instance at a time (conservative; re-evaluates after cooldown)
              value: '1'
              // cooldown: minimum time between scale actions — prevents thrashing.
              // 5 minutes = platform needs time to provision and warm up new instances
              cooldown: 'PT5M'
            }
          }
          {
            // Scale-IN rule: remove an instance when CPU is low (cost reduction)
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: appServicePlan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              // Longer time window (10 min) for scale-in prevents premature scale-in
              // during brief traffic dips followed by spikes
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              // Trigger fires when 10-min average CPU < 25%
              operator: 'LessThan'
              threshold: 25
            }
            scaleAction: {
              // 'Decrease' = scale in (remove instances)
              direction: 'Decrease'
              type: 'ChangeCount'
              // Remove 1 instance at a time — gradual scale-in is safer than
              // aggressive removal which could spike remaining instance load
              value: '1'
              // 10-minute cooldown for scale-in; longer than scale-out cooldown
              // to ensure the remaining instances absorb load before further reduction
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

// ── Web App Diagnostics ───────────────────────────────────────────────────
// Diagnostic settings route App Service log categories to Log Analytics.
// These logs enable troubleshooting HTTP errors, application crashes,
// and platform-level events from a single query interface.

resource webAppDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  // scope pins diagnostics to this specific web app resource
  scope: webApp
  properties: {
    // Destination Log Analytics Workspace ARM resource ID
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      // HTTP access logs: request method, URL, status code, response time;
      // essential for traffic analysis and error rate alerting
      { category: 'AppServiceHTTPLogs', enabled: true }
      // Console output (stdout/stderr) from the application process;
      // captures print statements, unhandled exceptions, and crash output
      { category: 'AppServiceConsoleLogs', enabled: true }
      // Application-level structured logs written via App Service logging APIs
      // (e.g. ILogger in .NET, console in Node.js when trace logging is enabled)
      { category: 'AppServiceAppLogs', enabled: true }
      // Platform events: auto-heal triggers, instance restarts, slot swaps,
      // scaling events — useful for correlating app issues with platform changes
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
    metrics: [
      // AllMetrics: CPU percentage, memory working set, request count,
      // data in/out, HTTP error rates — used for dashboards and alert rules
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

// Short name of the web app; used in deployment commands (az webapp deploy)
// and for constructing the default hostname manually
output webAppName string = webApp.name

// Default hostname (e.g. myapp.azurewebsites.net) for health checks, DNS
// CNAME records, and Application Gateway backend pool configuration
output webAppDefaultHostname string = webApp.properties.defaultHostName

// Azure AD Object (Principal) ID of the web app's system-assigned identity;
// used to grant the app RBAC roles (e.g. Key Vault Secrets User, Storage
// Blob Data Reader) in other modules or main.bicep
output webAppPrincipalId string = webApp.identity.principalId

// ARM resource ID of the App Service Plan; used to reference the plan in
// autoscale settings, additional web apps, or Function App assignments
output appServicePlanId string = appServicePlan.id
