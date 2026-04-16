// ============================================================================
// Storage — Blob + Files with lifecycle management, private endpoint ready
// AZ-104 scope: Managing Azure Storage (blob, files, lifecycle, diagnostics)
// ============================================================================

// param location string
// Receives the Azure region (e.g., 'eastus2') from the parent/orchestrator template.
// Co-locating storage with compute in the same region avoids cross-region egress
// charges and reduces latency — a key cost-management consideration for AZ-104.
param location string

// param environment string
// A deployment-stage discriminator (e.g., 'dev', 'staging', 'prod').
// Drives conditional logic throughout this module (redundancy tier, retention days)
// so a single template serves all environments without code duplication.
param environment string

// param orgPrefix string
// Short organisation identifier (e.g., 'contoso') prepended to every resource name.
// Provides a human-readable namespace inside a subscription that may host multiple
// tenants or projects — essential for governance at scale (AZ-104: resource naming).
param orgPrefix string

// param tags object
// An object of key-value pairs (e.g., { CostCenter: 'IT', Owner: 'ops@contoso.com' }).
// Tags are the primary mechanism for billing attribution, RBAC scope filtering, and
// policy compliance checks — all core AZ-104 governance responsibilities.
param tags object

// param logAnalyticsWorkspaceId string
// Resource ID of an existing Log Analytics Workspace to receive diagnostic logs.
// Centralising logs from all storage operations into a single workspace enables
// cross-resource queries (KQL) and satisfies audit/compliance requirements (AZ-104:
// Monitor and back up Azure resources).
param logAnalyticsWorkspaceId string

// ── Variables ───────────────────────────────────────────────────────────────

// Storage account names: 3-24 chars, lowercase alphanumeric only
// (Azure naming rule enforced by the take() call below)

// var storageAccountName
// Builds a deterministic but globally-unique name by combining:
//   orgPrefix  — human-readable ownership signal
//   'st'       — resource-type abbreviation (Microsoft CAF naming convention)
//   environment — deployment stage for quick visual identification
//   uniqueString(resourceGroup().id) — 13-char hash derived from the resource group's
//     immutable ID, guaranteeing uniqueness across all Azure subscriptions without
//     needing a random suffix that would change on every deployment.
var storageAccountName = '${orgPrefix}st${environment}${uniqueString(resourceGroup().id)}'

// var redundancy
// Selects the Storage SKU replication tier using a ternary conditional:
//   'GRS'  (Geo-Redundant Storage) for prod — replicates data asynchronously to a
//          paired region, providing RPO ~15 min and protecting against regional
//          outages; mandatory for business-critical workloads (AZ-104: HA & DR).
//   'LRS'  (Locally Redundant Storage) for non-prod — three synchronous copies within
//          one datacenter; lower cost, acceptable for ephemeral dev/test data.
// Other SKU options not used here: ZRS (zone-redundant), GZRS (geo+zone-redundant).
var redundancy = environment == 'prod' ? 'GRS' : 'LRS'

// ── Storage Account ────────────────────────────────────────────────────────

// resource storageAccount — Microsoft.Storage/storageAccounts@2023-01-01
// The top-level Storage Account is the billing and access-control boundary for all
// storage services (Blob, Files, Queue, Table) contained within it.
// Pinning to a specific API version (2023-01-01) ensures deterministic deployments
// and prevents unintentional schema drift when Microsoft releases new API versions.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {

  // take(storageAccountName, 24) — truncates the computed name to 24 characters,
  // which is Azure's hard limit for storage account names (3–24 lowercase alphanumeric).
  // Without take(), a long orgPrefix + environment combination could breach the limit
  // and cause a deployment failure that is hard to diagnose at runtime.
  name: take(storageAccountName, 24)

  // Deploys the account to the same region passed in via the location parameter.
  // Matching the region of dependent resources (VMs, App Services) minimises latency
  // and eliminates inter-region data-transfer charges.
  location: location

  // Applies the shared tag set inherited from the parent deployment.
  // Tags on the storage account propagate to cost-analysis views in Cost Management
  // and are evaluated by Azure Policy for compliance reporting (AZ-104: governance).
  tags: tags

  // kind: 'StorageV2' — General Purpose v2; the current recommended account type.
  // GPv2 supports all storage services (Blob, Files, Queue, Table), all redundancy
  // SKUs, and tiered access (Hot / Cool / Archive) — none of which are available
  // on the legacy BlobStorage or GPv1 kinds.
  kind: 'StorageV2'

  sku: {
    // 'Standard_${redundancy}' expands to either 'Standard_GRS' or 'Standard_LRS'
    // at deploy time based on the redundancy variable resolved above.
    // Standard = HDD-backed magnetic media, appropriate for bulk/backup workloads.
    // Use 'Premium_LRS' or 'Premium_ZRS' for high-IOPS workloads (page blobs, NFS shares).
    name: 'Standard_${redundancy}'
  }

  properties: {
    // accessTier: 'Hot' — default access tier applied to blobs that have not been
    // explicitly assigned a tier.  Hot tier has higher storage cost but lower per-
    // operation cost, making it appropriate for frequently-accessed application data.
    // The lifecycle policy below overrides this for older backups/logs automatically.
    accessTier: 'Hot'

    // supportsHttpsTrafficOnly: true — rejects all plain HTTP requests to the
    // storage endpoints.  This is an AZ-104 security baseline requirement: data in
    // transit must be encrypted with TLS.  Azure Defender for Storage flags accounts
    // where this is false as a high-severity finding.
    supportsHttpsTrafficOnly: true

    // minimumTlsVersion: 'TLS1_2' — refuses TLS 1.0 and TLS 1.1 handshakes, which
    // have known cryptographic weaknesses (BEAST, POODLE).  TLS 1.2 is the current
    // organisational and regulatory floor; TLS 1.3 is not yet universally supported
    // by all Azure SDK clients so 1.2 remains the practical minimum.
    minimumTlsVersion: 'TLS1_2'

    // allowBlobPublicAccess: false — prevents any container from being configured
    // with PublicAccessLevel = Blob or Container.  Blob-level or container-level
    // public access would allow unauthenticated reads from the internet, which is
    // inappropriate for enterprise storage (AZ-104: Secure access to storage).
    allowBlobPublicAccess: false

    // allowSharedKeyAccess: true — permits authentication via the 512-bit storage
    // account key (the classic connection string approach).  This is currently enabled
    // to support legacy applications that have not yet migrated to Azure AD / RBAC.
    // The inline comment flags this as technical debt: once all clients use Entra ID
    // (AAD) tokens or Managed Identities, this should be set to false to eliminate
    // the shared-secret attack surface (AZ-104: Configure storage account keys).
    allowSharedKeyAccess: true               // Disable after RBAC migration

    // networkAcls — the storage firewall; controls which network paths can reach
    // the public storage endpoints (blob.core.windows.net, file.core.windows.net).
    networkAcls: {
      // defaultAction: 'Deny' — default-deny posture; all traffic is blocked unless
      // explicitly permitted by an ipRule or virtualNetworkRule below.
      // This is the "private endpoint ready" stance referenced in the module header:
      // public network access is locked down, and a Private Endpoint (defined elsewhere)
      // provides the approved ingress path inside the VNet (AZ-104: Private endpoints).
      defaultAction: 'Deny'

      // bypass: 'AzureServices' — allows trusted Microsoft first-party services
      // (Azure Backup, Azure Site Recovery, Azure Monitor, etc.) to reach the account
      // even when the firewall is set to Deny.  Without this, backup jobs and
      // diagnostic pipelines would fail silently because their source IPs are not
      // fixed and cannot be added to ipRules.
      bypass: 'AzureServices'

      // ipRules: [] — no public IP ranges are explicitly whitelisted.
      // In a production hardening scenario this array would contain static NAT IPs
      // for on-premises management hosts or CI/CD runners that need direct access.
      ipRules: []

      // virtualNetworkRules: [] — no Service Endpoint rules are defined here.
      // Service Endpoints are a lighter-weight alternative to Private Endpoints that
      // route traffic over the Azure backbone without requiring a private IP.
      // An empty array reflects the design choice to use Private Endpoints exclusively.
      virtualNetworkRules: []
    }

    encryption: {
      // keySource: 'Microsoft.Storage' — uses Microsoft-managed encryption keys (MMK).
      // All data is encrypted at rest with AES-256 automatically; Microsoft rotates
      // the keys on a schedule transparent to the customer.
      // The alternative, 'Microsoft.Keyvault', enables Customer-Managed Keys (CMK)
      // via Azure Key Vault for regulatory scenarios requiring key ownership proof.
      keySource: 'Microsoft.Storage'

      services: {
        // blob encryption — encrypts every blob object at rest.
        // keyType: 'Account' means one encryption key covers all blobs in the account
        // (as opposed to 'Service' scope, which is a legacy option no longer recommended).
        blob: { enabled: true, keyType: 'Account' }

        // file encryption — encrypts SMB/NFS shares at rest.
        // Required for compliance frameworks (ISO 27001, SOC 2) that mandate
        // encryption of data at rest for file-based workloads.
        file: { enabled: true, keyType: 'Account' }
      }
    }
  }
}

// ── Blob Service ───────────────────────────────────────────────────────────

// resource blobService — Microsoft.Storage/storageAccounts/blobServices@2023-01-01
// The blobServices child resource configures Blob-specific data-protection settings.
// Despite being a child resource, it must be explicitly deployed to activate features
// such as soft delete and versioning — they are NOT on by default at account creation.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {

  // parent: storageAccount — Bicep parent syntax automatically constructs the
  // hierarchical ARM resource ID (<accountName>/blobServices/default) and ensures
  // the storage account exists before this child resource is created.
  parent: storageAccount

  // name: 'default' — the blob service child resource is a singleton; 'default' is
  // the only valid name.  ARM requires this literal string.
  name: 'default'

  properties: {
    // deleteRetentionPolicy — blob-level soft delete.
    // When a blob is deleted it enters a soft-deleted state for the configured
    // number of days before permanent removal.  Administrators can restore blobs
    // during this window via the portal, CLI, or REST API (AZ-104: data protection).
    deleteRetentionPolicy: {
      enabled: true

      // Retention window is environment-conditional:
      //   prod  → 30 days, matching typical enterprise RTO/RPO requirements and
      //           giving the ops team a full month to detect accidental deletions.
      //   non-prod → 7 days, sufficient to catch mistakes without inflating
      //              storage costs for ephemeral dev/test data.
      days: environment == 'prod' ? 30 : 7
    }

    // containerDeleteRetentionPolicy — container-level soft delete.
    // Protects against accidental deletion of an entire container (which would
    // normally make all blobs inside it instantly unrecoverable).  The container
    // can be restored for up to 7 days after deletion regardless of environment,
    // because container-level recovery is a low-cost safety net.
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }

    // changeFeed — an ordered, durable log of every create, modify, and delete
    // event on blobs in the account.  Required for:
    //   - Audit trails proving what changed and when (compliance).
    //   - Event-driven pipelines that react to blob mutations without polling.
    //   - Incremental backup and data-replication solutions (AZ-104: backup strategy).
    changeFeed: {
      enabled: true
    }

    // isVersioningEnabled: true — every write to an existing blob automatically
    // preserves the prior content as an immutable previous version.  Combined with
    // soft delete, this provides a two-layer protection model:
    //   Layer 1 (versioning) — retain all historical states of a blob.
    //   Layer 2 (soft delete) — recover from an accidental delete of the current version.
    // The lifecycle policy below cleans up old versions after 60 days to control cost.
    isVersioningEnabled: true
  }
}

// ── Blob Containers ────────────────────────────────────────────────────────
// Containers are the logical namespace within Blob storage — analogous to a
// top-level folder.  Access control (RBAC, SAS tokens, ACLs) can be scoped to
// an individual container, allowing least-privilege assignments per workload.

// resource appDataContainer — holds application runtime data (config blobs,
// user uploads, processed artefacts).  Separating app data from backups and logs
// isolates blast radius: a misconfigured app can only affect its own container.
resource appDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService // Bicep resolves the full ARM path: <account>/blobServices/default/containers/app-data
  name: 'app-data'   // Container names must be 3–63 chars, lowercase, hyphens allowed
  properties: {
    // publicAccess: 'None' — no anonymous HTTP access; all requests must present a
    // valid Entra ID token, SAS token, or account key.  This is mandatory given
    // allowBlobPublicAccess: false set at the account level; setting it here as well
    // is defensive in case the account-level setting is ever relaxed (AZ-104: least privilege).
    publicAccess: 'None'
  }
}

// resource backupsContainer — stores VM backup data and disk snapshots generated by
// Azure Backup or custom scripts.  The metadata tag makes the container's purpose
// discoverable via ARM queries and policy conditions without inspecting blob contents.
resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'backups'
  properties: {
    // Same default-deny public access posture as all other containers.
    publicAccess: 'None'

    // metadata — arbitrary key-value strings stored alongside the container resource.
    // Unlike tags (which are an ARM concept), container metadata is a storage-plane
    // property surfaced via the Blob REST API.  Useful for tooling that discovers
    // containers programmatically (e.g., a backup rotation script that queries
    // metadata to find containers holding snapshots).
    metadata: {
      purpose: 'vm-backups-and-snapshots'
    }
  }
}

// resource logsContainer — receives diagnostic logs exported by other Azure services
// (e.g., NSG flow logs, Activity Log archive, App Service logs) that target Blob
// storage rather than Log Analytics.  Keeping logs isolated in their own container
// allows a tighter RBAC assignment: the log-writer identity (e.g., a Managed Identity
// or the Azure Monitor service principal) needs only Storage Blob Data Contributor
// on this container, not on the entire account.
resource logsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'diagnostic-logs'
  properties: {
    // No public access; log data often contains sensitive operational detail and
    // should be accessible only to security/ops personnel via RBAC.
    publicAccess: 'None'
  }
}

// ── File Share ─────────────────────────────────────────────────────────────
// Azure Files provides a fully-managed SMB 3.x / NFS 4.1 file share mounted by
// VMs and containers as a persistent, shared network drive — equivalent to an
// on-premises file server without the management overhead (AZ-104: Azure Files).

// resource fileService — Microsoft.Storage/storageAccounts/fileServices@2023-01-01
// Like blobServices, this is a singleton child resource that must be deployed to
// configure file-share-level protection policies.  The parent storage account's
// encryption settings (AES-256) also apply to all file shares automatically.
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount // The storage account must exist before the file service
  name: 'default'        // Only valid value; ARM enforces this as a singleton

  properties: {
    // shareDeleteRetentionPolicy — soft delete for Azure file shares.
    // If a share is accidentally deleted (e.g., 'az storage share delete'), it can
    // be recovered for up to 14 days before permanent deletion.  14 days is a common
    // enterprise standard: long enough to detect a mistake during an on-call rotation,
    // short enough to comply with data-minimisation policies.
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14 // Fixed at 14 days across all environments — share deletion is rare
               // enough that the same window is acceptable for prod and non-prod.
    }
  }
}

// resource configShare — an Azure file share used to distribute application
// configuration files to compute resources (VMs, AKS pods, App Service).
// Using a shared file system avoids baking config into VM images or container
// images, enabling runtime configuration changes without redeployment.
resource configShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'config-share' // Share name: 3–63 chars, lowercase, hyphens allowed

  properties: {
    // shareQuota: 50 — maximum capacity of the share in GiB.
    // Setting an explicit quota prevents a runaway process from filling the share
    // and starving other workloads.  50 GiB is generous for config files while
    // remaining well below the 100 TiB maximum for Standard shares.
    shareQuota: 50

    // accessTier: 'TransactionOptimized' — optimised for high transaction rates
    // with modest stored data volume, which matches configuration-file access
    // patterns (frequent small reads, infrequent writes).
    // Other tiers: Hot (highest storage cost, low transaction cost — large active
    // datasets), Cool (lowest storage cost, high transaction cost — infrequent access).
    // TransactionOptimized is the practical default for most SMB workloads.
    accessTier: 'TransactionOptimized'
  }
}

// ── Lifecycle Management ───────────────────────────────────────────────────
// Azure Blob Lifecycle Management automates cost optimisation by moving blobs
// between access tiers (Hot → Cool → Archive) and deleting expired data based
// on age rules evaluated nightly by the platform (AZ-104: Manage storage costs).
// This eliminates the need for custom scripts or cron jobs to tier old data.

// resource lifecyclePolicy — Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01
// A singleton child resource of the storage account.  Only one management policy
// per account is allowed; all rules must be packed into this single resource.
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default' // Required singleton name — ARM enforces this literal value

  properties: {
    policy: {
      rules: [

        // ── Rule 1: Tier backups and diagnostic logs through Hot → Cool → Archive → Delete
        {
          // name — human-readable rule identifier visible in the portal; must be unique
          // within the policy.  Descriptive names speed up troubleshooting.
          name: 'move-to-cool-after-30d'

          // enabled: true — the rule is active.  Setting false suspends evaluation
          // without removing the rule definition (useful during incident response).
          enabled: true

          // type: 'Lifecycle' — the only valid value; reserved for future rule types.
          type: 'Lifecycle'

          definition: {
            filters: {
              // blobTypes: ['blockBlob'] — targets only block blobs.
              // Block blobs are the standard type for general-purpose storage
              // (uploads, backups, logs).  Append blobs (log streaming) and page blobs
              // (VHDs) are intentionally excluded from this tiering rule.
              blobTypes: ['blockBlob']

              // prefixMatch — scopes the rule to blobs whose names start with these
              // container-path prefixes.  Only blobs in 'backups/' and 'diagnostic-logs/'
              // are tiered; app-data blobs in 'app-data/' remain in Hot tier because
              // they are frequently accessed by the running application.
              // The trailing slash is important: without it, 'backups' would also
              // match a hypothetical container named 'backups-archive'.
              prefixMatch: ['backups/', 'diagnostic-logs/']
            }

            actions: {
              // baseBlob — actions applied to the current (live) version of the blob.
              baseBlob: {
                // tierToCool — moves blobs to Cool tier after 30 days without modification.
                // Cool tier: ~50% cheaper storage cost than Hot, but per-operation cost
                // is higher.  Ideal for backups and logs that are read rarely after 30 days.
                // Cost break-even vs Hot occurs at roughly 30 reads/month per GB.
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }

                // tierToArchive — moves blobs to Archive tier after 90 days.
                // Archive tier: ~90% cheaper storage cost than Hot, but blobs are
                // offline and must be 'rehydrated' (restored to Hot/Cool) before they
                // can be read — rehydration takes 1–15 hours.  Only appropriate for
                // long-term retention data that would only ever be accessed for a
                // regulatory audit or disaster recovery investigation.
                tierToArchive: {
                  daysAfterModificationGreaterThan: 90
                }

                // delete — permanently removes blobs older than 365 days.
                // This enforces the data-retention policy: backup and log data older
                // than 1 year is considered expired.  Adjust this value to match
                // legal/regulatory retention requirements for the organisation.
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }

              // snapshot — actions applied to blob snapshots (manual point-in-time copies).
              // Snapshots older than 90 days are deleted because:
              //   1. Blob versioning (enabled above) supersedes manual snapshots for
              //      change history, making old snapshots redundant.
              //   2. Retaining snapshots indefinitely doubles storage cost for every
              //      version of a blob that has a snapshot.
              snapshot: {
                delete: {
                  daysAfterCreationGreaterThan: 90 // Snapshots expire after 90 days
                }
              }
            }
          }
        }

        // ── Rule 2: Purge old blob versions to control versioning storage overhead
        {
          name: 'delete-old-versions'
          enabled: true
          type: 'Lifecycle'

          definition: {
            filters: {
              // Applies to all block blobs across the entire account (no prefixMatch),
              // because version accumulation is a cost concern for every container:
              // without this rule, every overwrite of every blob retains all prior
              // versions indefinitely (since isVersioningEnabled: true above).
              blobTypes: ['blockBlob']
            }

            actions: {
              // version — actions applied to non-current (historical) blob versions.
              // Previous versions that are older than 60 days are permanently deleted.
              // 60 days provides a comfortable recovery window beyond the soft-delete
              // retention period (30 days prod / 7 days non-prod), while preventing
              // unbounded version accumulation that would inflate storage costs over time.
              version: {
                delete: {
                  daysAfterCreationGreaterThan: 60
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ── Storage Diagnostics ────────────────────────────────────────────────────
// Diagnostic settings are the Azure-native mechanism for routing resource logs
// and metrics to one or more destinations (Log Analytics, Storage, Event Hub).
// For storage accounts, diagnostic settings must be configured at the service
// level (blobServices, fileServices, etc.) rather than the account level, because
// the account-level resource does not emit data-plane operation logs.

// resource storageDiag — Microsoft.Insights/diagnosticSettings@2021-05-01-preview
// Attaches a diagnostic configuration to the blobService resource so that every
// read, write, and delete operation against blobs is logged in Log Analytics.
// This enables security investigations, compliance audits, and cost attribution
// queries (AZ-104: Monitor and troubleshoot storage).
resource storageDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {

  // name: 'send-to-law' — a descriptive label for the diagnostic setting.
  // Up to 5 diagnostic settings can be created per resource, each sending to a
  // different destination.  A clear name like 'send-to-law' avoids confusion
  // when multiple settings exist (e.g., 'send-to-eventhub' for SIEM streaming).
  name: 'send-to-law'

  // scope: blobService — attaches this diagnostic setting to the blob service
  // child resource specifically.  Using the Bicep resource reference (rather than
  // a hard-coded resource ID) ensures the setting is deployed after the blob
  // service resource is created and resolves the correct ARM resource ID automatically.
  scope: blobService

  properties: {
    // workspaceId — the ARM resource ID of the target Log Analytics Workspace.
    // All log and metric data flows to this workspace, where it can be queried
    // with KQL (Kusto Query Language) across all resources in the environment.
    // Centralising in a single workspace reduces per-GB ingestion cost compared
    // to per-resource workspaces and enables cross-resource correlation.
    workspaceId: logAnalyticsWorkspaceId

    logs: [
      // StorageRead — logs GET, HEAD, and LIST operations on blobs.
      // Useful for detecting unexpected data exfiltration (a blob being read by an
      // unfamiliar IP or service principal) and for access-pattern analysis.
      { category: 'StorageRead', enabled: true }

      // StorageWrite — logs PUT, POST, and COPY operations (blob creation/modification).
      // Essential for change auditing: provides a timestamped record of every blob
      // upload, overwrite, or metadata change, including the caller identity and IP.
      { category: 'StorageWrite', enabled: true }

      // StorageDelete — logs DELETE operations on blobs and containers.
      // Critical for incident response: if data goes missing, this log category
      // confirms whether it was deleted, who deleted it, and from what IP/identity,
      // supporting forensic investigation and insider-threat detection.
      { category: 'StorageDelete', enabled: true }
    ]

    metrics: [
      // Transaction metric — counts of storage API calls, broken down by response
      // type (success, throttle, client error, server error), authentication type,
      // and API operation name.
      // Key use-cases:
      //   - Alerting on a spike in ThrottlingError (account is hitting IOPS limits).
      //   - Chargebacks: correlating transaction counts to cost by container prefix.
      //   - SLA validation: measuring P99 end-to-end latency for application teams.
      { category: 'Transaction', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
// Outputs surface runtime-resolved values back to the calling template (or to the
// 'az deployment' CLI) so that other modules can consume this storage account
// without hard-coding resource names or IDs — a key IaC best practice.

// output storageAccountName — the final resolved name (post-take() truncation).
// Consumers use this to construct connection strings or reference the account
// in Azure CLI scripts (e.g., 'az storage blob list --account-name <name>').
output storageAccountName string = storageAccount.name

// output storageAccountId — the fully-qualified ARM resource ID.
// Used by downstream modules (e.g., Private Endpoint, Role Assignment, Backup Policy)
// that need to reference this storage account as a scope or dependency without
// hard-coding subscription/resource-group details.
output storageAccountId string = storageAccount.id

// output blobEndpoint — the public HTTPS URL for the Blob service
// (e.g., https://<name>.blob.core.windows.net/).
// Applications and CI pipelines use this endpoint to construct blob URIs.
// Even though network access is restricted to Private Endpoints, the public FQDN
// is still needed because Private DNS overrides it to resolve to the private IP.
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

// output fileEndpoint — the public HTTPS/SMB URL for the Azure Files service
// (e.g., https://<name>.file.core.windows.net/).
// Passed to VM configuration scripts or AKS PersistentVolume definitions that
// mount the config-share via the Azure Files CSI driver.
output fileEndpoint string = storageAccount.properties.primaryEndpoints.file
