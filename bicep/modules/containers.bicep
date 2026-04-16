// ============================================================================
// Containers — Azure Container Instances + Azure Container Registry
// AZ-104 Domain: Deploy and manage Azure compute resources
// Azure Container Registry (ACR) is a private Docker-compatible registry for
// storing and managing container images. Azure Container Instances (ACI) runs
// containers on-demand without managing VMs or orchestrators — suitable for
// short-lived tasks, sidecars, and job runners.
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region for all container resources
param location string

// Deployment environment (dev / staging / prod) — drives ACR SKU selection
param environment string

// Short organization prefix for resource naming
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// ARM resource ID of the VNet subnet for ACI VNet injection; allows private
// ACI containers to communicate with VMs and other private resources
param appSubnetId string

// Resource ID of the Log Analytics Workspace for ACR diagnostic streaming
// and ACI container log collection
param logAnalyticsWorkspaceId string

// ── Azure Container Registry ──────────────────────────────────────────────
// ACR is the private container image registry. Images are pushed here from
// CI/CD pipelines and pulled by ACI, AKS, App Service, and VMSS.
// ACR name must be globally unique, 5–50 alphanumeric characters, no hyphens.

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  // Name must be globally unique and contain only alphanumeric chars (no hyphens);
  // uniqueString() provides deterministic uniqueness per resource group
  name: '${orgPrefix}acr${environment}${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: {
    // Standard SKU for prod: supports geo-replication, content trust, and higher
    // throughput limits. Standard storage is 100 GB included; webhooks supported.
    // Basic SKU for non-prod: sufficient for dev/test; lower included storage (10 GB),
    // no geo-replication. Basic is cheapest option for image hosting.
    name: environment == 'prod' ? 'Standard' : 'Basic'
  }
  properties: {
    // adminUserEnabled: false disables the legacy admin username/password credential.
    // All access uses managed identities or service principals with RBAC roles
    // (AcrPull, AcrPush, AcrDelete). This prevents shared credential sprawl.
    adminUserEnabled: false                    // Use managed identity, not admin
    // publicNetworkAccess: 'Enabled' allows pulls from anywhere with valid credentials.
    // For higher security, restrict to Private Endpoint + 'Disabled' public access.
    publicNetworkAccess: 'Enabled'
    policies: {
      retentionPolicy: {
        // Retention policy automatically purges untagged manifests (dangling images)
        // older than the specified number of days. Keeps the registry clean and
        // reduces storage costs for environments with frequent image builds.
        status: 'enabled'
        // 30-day retention: untagged images older than 30 days are automatically deleted
        days: 30
      }
    }
  }
}

// ── Container Instance: Monitoring Sidecar ────────────────────────────────
// ACI is used here as a lightweight sidecar container that continuously polls
// an internal application health endpoint. Runs persistently (restartPolicy: Always).
// VNet injection (subnetIds) places the container on the private VNet so it can
// reach internal load balancer IPs without public IP exposure.

resource monitoringContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  // Container group name — all containers within share the same network namespace
  name: '${orgPrefix}-aci-monitor-${environment}'
  location: location
  tags: tags
  properties: {
    // osType: 'Linux' — required for Linux container images (curl-based image below)
    osType: 'Linux'
    // restartPolicy: 'Always' restarts all containers in the group if any exit.
    // Appropriate for long-running sidecars that should always be running.
    // Other options: 'OnFailure' (restart on non-zero exit), 'Never' (run-once jobs)
    restartPolicy: 'Always'
    // 'Standard' SKU provides standard compute; 'Dedicated' provides isolated hosts
    sku: 'Standard'
    containers: [
      {
        // Container name within the group; used in 'az container logs' commands
        name: 'health-checker'
        properties: {
          // Public image from Docker Hub; in production, pull from ACR instead
          // to avoid rate limiting and ensure image provenance
          image: 'curlimages/curl:latest'
          // command overrides the image ENTRYPOINT; runs an infinite loop that
          // polls the internal app health endpoint every 30 seconds
          command: [
            '/bin/sh'
            '-c'
            // Polls http://10.1.1.4/health (internal LB IP) every 30 seconds.
            // 'curl -sf' = silent + fail-on-HTTP-error. Logs UNHEALTHY with
            // timestamp if the health check fails. ACI stdout feeds to Log Analytics.
            'while true; do curl -sf http://10.1.1.4/health || echo "UNHEALTHY $(date)"; sleep 30; done'
          ]
          resources: {
            requests: {
              // 1 vCPU allocated to the health-checker container.
              // ACI billing is per vCPU-second; minimal allocation reduces cost.
              cpu: 1
              // 1 GB memory allocation; more than sufficient for a curl loop
              memoryInGB: 1
            }
          }
          environmentVariables: [
            {
              // Environment variable available inside the container at runtime;
              // allows the script to log which environment it is monitoring
              name: 'ENVIRONMENT'
              value: environment
            }
          ]
        }
      }
    ]
    diagnostics: {
      logAnalytics: {
        // reference() retrieves the Log Analytics workspace's customerId (workspace ID
        // GUID) at deployment time; used by ACI to authenticate log uploads
        workspaceId: reference(logAnalyticsWorkspaceId, '2022-10-01').customerId
        // listKeys() retrieves the primary shared key for the Log Analytics workspace;
        // ACI uses this key to authenticate when sending container stdout/stderr logs.
        // Note: this exposes the key in the deployment; prefer using managed identity
        // log collection (preview feature) in production environments.
        workspaceKey: listKeys(logAnalyticsWorkspaceId, '2022-10-01').primarySharedKey
      }
    }
    ipAddress: {
      // 'Private' type: container is reachable only within the VNet via its private IP.
      // No public IP is assigned; access from internet is not possible.
      type: 'Private'
      ports: [
        // Expose TCP port 80 within the container group's network namespace.
        // Required even for internal-only containers to define listening ports.
        { port: 80, protocol: 'TCP' }
      ]
    }
    // subnetIds injects the container group into the VNet subnet (VNet integration).
    // The container receives a private IP from the subnet's address range and
    // can communicate with other VNet resources (VMs, private endpoints, etc.)
    subnetIds: [
      { id: appSubnetId }
    ]
  }
}

// ── Container Instance: Utility/Job Runner ────────────────────────────────
// A general-purpose container group for ad-hoc administrative tasks such as
// data migrations, AZCopy operations, or scripted maintenance jobs.
// restartPolicy: 'OnFailure' makes it suitable for one-off or scheduled jobs
// that should retry on failure but stop when they succeed.

resource utilityContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${orgPrefix}-aci-utility-${environment}'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    // 'OnFailure': ACI restarts the container only if it exits with a non-zero
    // code, making this suitable for job-style workloads that should complete
    // successfully and then stop (no infinite restart loop)
    restartPolicy: 'OnFailure'
    containers: [
      {
        // Container name used to identify this container in logs and exec sessions
        name: 'azcopy-backup'
        properties: {
          // Azure CLI image from MCR; pre-installed with azcopy, azure-cli,
          // and common utilities for administrative scripting tasks
          image: 'mcr.microsoft.com/azure-cli:latest'
          // Default command prints a readiness message; override at runtime
          // using 'az container exec' or by re-deploying with a specific command
          command: [
            '/bin/sh'
            '-c'
            'echo "Utility container ready for ad-hoc tasks"'
          ]
          resources: {
            requests: {
              // 1 vCPU for CLI operations; increase for CPU-intensive data processing
              cpu: 1
              // 2 GB memory: more than the health-checker because CLI tools and
              // azcopy operations benefit from additional memory for buffering
              memoryInGB: 2
            }
          }
        }
      }
    ]
    ipAddress: {
      // 'Public' type: ACI assigns a public IP for direct internet connectivity.
      // Useful for the utility container to reach external endpoints (storage,
      // APIs) without routing through a VNet. Note: no subnetIds here since this
      // container is not VNet-injected.
      type: 'Public'
      ports: [
        // Port 80 exposed for potential webhook callbacks or management endpoints
        { port: 80, protocol: 'TCP' }
      ]
    }
  }
}

// ── ACR Diagnostics ───────────────────────────────────────────────────────
// Diagnostic settings stream ACR activity to Log Analytics, enabling:
//   - Detection of unauthorized image push/pull attempts
//   - Audit trail of image deletions and repository changes
//   - Registry quota and performance monitoring

resource acrDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  // scope pins the diagnostic setting to this specific ACR resource
  scope: acr
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      // 'allLogs' captures ContainerRegistryLoginEvents (auth attempts),
      // ContainerRegistryRepositoryEvents (push, pull, delete operations)
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      // AllMetrics: storage used, successful/failed pull-through, run durations
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

// Short ACR name; used in 'docker tag' and 'docker push' commands to prefix
// image names: <acrName>.azurecr.io/<image>:<tag>
output acrName string = acr.name

// Fully-qualified login server hostname (e.g. myacr.azurecr.io);
// used in CI/CD pipeline image tag and push commands, and in ACI/AKS
// image pull references
output acrLoginServer string = acr.properties.loginServer

// ARM resource ID of the monitoring container group; used for status checks
// and to reference the container in automation runbooks
output monitoringContainerId string = monitoringContainer.id
