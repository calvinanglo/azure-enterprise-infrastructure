// ============================================================================
// Backup & Recovery — Recovery Services Vault, VM backup policies, file recovery
// AZ-104 Domain: Implement and manage storage / Deploy and manage compute
// Recovery Services Vault (RSV) is the container for Azure Backup and Azure
// Site Recovery. It stores backup data, enforces retention policies, and
// provides restore capabilities. Backup policies define the schedule (when to
// back up) and retention (how long to keep each recovery point).
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region where the Recovery Services Vault is deployed. Backup data is
// stored in the same region by default (GRS replicates to a paired region).
param location string

// Deployment environment (dev / staging / prod) — drives retention period lengths
// (prod retains data longer to meet RPO/RTO requirements and compliance obligations)
param environment string

// Short organization prefix used in the vault and policy resource names
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// Resource ID of the Log Analytics Workspace that receives vault diagnostic logs;
// enables alerting on backup job failures and compliance reporting
param logAnalyticsWorkspaceId string

// ── Recovery Services Vault ────────────────────────────────────────────────
// The RSV is the top-level container. All backup policies, backup items, and
// recovery points live within a single vault. One vault per region per workload
// is a common design pattern to isolate blast radius.

resource rsVault 'Microsoft.RecoveryServices/vaults@2023-06-01' = {
  // Naming convention: <prefix>-rsv-<environment>
  // RSV names must be globally unique within the region
  name: '${orgPrefix}-rsv-${environment}'
  location: location
  tags: tags
  sku: {
    // 'RS0' is the only SKU name for Recovery Services Vaults (legacy naming)
    name: 'RS0'
    // 'Standard' tier supports Azure Backup and Azure Site Recovery features
    tier: 'Standard'
  }
  properties: {
    // Public network access enabled for initial setup. In production, consider
    // restricting to Private Endpoints so backup traffic stays within the VNet.
    publicNetworkAccess: 'Enabled'
    securitySettings: {
      softDeleteSettings: {
        // Soft delete prevents backup data from being permanently removed for the
        // retention period even if someone deletes a backup item or the vault.
        // This protects against ransomware attacks that attempt to destroy backups.
        softDeleteState: 'Enabled'
        // 14-day soft delete window: deleted backup data is recoverable for 14 days.
        // Azure minimum is 14 days; consider increasing to 30 days for prod.
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

// ── Backup Policy: Daily VM Backup ─────────────────────────────────────────
// A backup policy attached to this vault defines the schedule and retention
// for Azure IaaS VM backups. VMs are enrolled into a policy via
// 'protectedItems' resources (wired in main.bicep or a separate module).

resource vmBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  // parent links this policy to the RSV above; it cannot exist without a vault
  parent: rsVault
  // Policy name must be unique within the vault; referenced when enrolling VMs
  name: 'policy-vm-daily'
  properties: {
    // 'AzureIaasVM' targets Azure virtual machines (both Windows and Linux).
    // Other valid values: AzureStorage (file shares), AzureWorkload (SQL, SAP HANA)
    backupManagementType: 'AzureIaasVM'
    // Number of days to retain instant restore snapshots (separate from vault
    // recovery points). Instant restore snapshots enable faster recoveries by
    // avoiding the full vault restore pipeline. Range: 1–5 days.
    instantRpRetentionRangeInDays: 2
    schedulePolicy: {
      // 'SimpleSchedulePolicy' supports daily or weekly backup schedules.
      // Use 'SimpleSchedulePolicyV2' for hourly backups (enhanced policy).
      schedulePolicyType: 'SimpleSchedulePolicy'
      // Daily frequency: one backup job runs every calendar day
      scheduleRunFrequency: 'Daily'
      // The time the backup job starts, expressed as a UTC datetime string.
      // Only the time portion (02:00:00Z) is used; the date is ignored.
      // 2 AM UTC = off-peak hours to minimize impact on VM performance.
      scheduleRunTimes: ['2024-01-01T02:00:00Z']    // 2 AM UTC
    }
    retentionPolicy: {
      // 'LongTermRetentionPolicy' allows independent retention periods for
      // daily, weekly, monthly, and yearly recovery points (GFS scheme).
      retentionPolicyType: 'LongTermRetentionPolicy'
      // Daily retention: keep the most recent N daily recovery points in the vault
      dailySchedule: {
        // The time that daily retention aligns to (must match scheduleRunTimes)
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          // Prod: 30-day daily retention for operational recovery (last-month restores)
          // Non-prod: 7-day retention to reduce storage costs in dev/test environments
          count: environment == 'prod' ? 30 : 7
          // 'Days' unit; other valid values: Weeks, Months, Years
          durationType: 'Days'
        }
      }
      // Weekly retention: keep one recovery point per week for N weeks
      weeklySchedule: {
        // Sunday weekly backup point provides a known weekly restore baseline
        daysOfTheWeek: ['Sunday']
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          // Prod: 12-week (3-month) weekly retention for medium-term recovery
          // Non-prod: 4-week retention
          count: environment == 'prod' ? 12 : 4
          durationType: 'Weeks'
        }
      }
      // Monthly retention: keep one recovery point per month for N months
      monthlySchedule: {
        // 'Weekly' format means the monthly retention point is taken from a specific
        // week/day combination rather than a fixed day-of-month date
        retentionScheduleFormatType: 'Weekly'
        retentionScheduleWeekly: {
          // First Sunday of each month is the monthly retention recovery point
          daysOfTheWeek: ['Sunday']
          // 'First' = first occurrence of the day in the calendar month
          weeksOfTheMonth: ['First']
        }
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          // Prod: 12-month (1-year) monthly retention for compliance/audit purposes
          // Non-prod: 3-month retention for recent historical restores
          count: environment == 'prod' ? 12 : 3
          durationType: 'Months'
        }
      }
    }
    // Backup job scheduling is calculated in this timezone. 'Eastern Standard Time'
    // = UTC-5 (EST) / UTC-4 (EDT). The scheduleRunTimes value is in UTC, but this
    // timezone setting affects how the Azure portal displays scheduled times.
    timeZone: 'Eastern Standard Time'
  }
}

// ── Backup Policy: File Share Backup ───────────────────────────────────────
// Azure Files (file shares in storage accounts) use a separate backup management
// type and policy. Azure Backup for Azure Files uses share snapshots stored in
// the same storage account (not the vault), with recovery points tracked in the vault.

resource fileBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  parent: rsVault
  // Policy name referenced when enrolling Azure File Shares into protection
  name: 'policy-fileshare-daily'
  properties: {
    // 'AzureStorage' targets Azure File Shares (not blob or table storage)
    backupManagementType: 'AzureStorage'
    // 'AzureFileShare' specifies the storage sub-type; required for file share policies
    workLoadType: 'AzureFileShare'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      // Daily frequency: one snapshot per day at the configured time
      scheduleRunFrequency: 'Daily'
      // 3 AM UTC — offset from VM backup time to stagger backup job load on the vault
      scheduleRunTimes: ['2024-01-01T03:00:00Z']
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        // Must match the scheduleRunTimes value above
        retentionTimes: ['2024-01-01T03:00:00Z']
        retentionDuration: {
          // 30-day daily retention for both prod and non-prod; file shares typically
          // contain shared documents that need longer baseline retention than VMs
          count: 30
          durationType: 'Days'
        }
      }
    }
    // Same timezone as the VM backup policy for consistency in scheduled job display
    timeZone: 'Eastern Standard Time'
  }
}

// ── Vault Diagnostics ─────────────────────────────────────────────────────
// Diagnostic settings send RSV operational events to Log Analytics. This enables:
//   - Alert rules on backup job failures (AzureBackupReport table)
//   - Compliance dashboards showing backup coverage and policy adherence
//   - Forensic investigation of restore operations

resource rsvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  // Descriptive name for the diagnostic setting shown in the portal
  name: 'send-to-law'
  // scope pins the diagnostic setting to this specific RSV resource
  scope: rsVault
  properties: {
    // Destination Log Analytics Workspace ARM resource ID
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      // 'allLogs' captures all log categories emitted by the RSV, including
      // AzureBackupReport (job status), CoreAzureBackup (policy/item events),
      // AddonAzureBackupJobs, and AzureSiteRecoveryEvents
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

// Short name of the RSV; used in CLI commands and automation scripts that
// need to enroll VMs into backup protection
output vaultName string = rsVault.name

// ARM resource ID of the RSV; used to scope RBAC assignments (e.g. Backup
// Contributor for the backup managed identity) and in policy compliance reports
output vaultId string = rsVault.id

// ARM resource ID of the VM backup policy; referenced when registering VM
// backup protection items (Microsoft.RecoveryServices/vaults/backupFabrics/
// protectionContainers/protectedItems)
output vmPolicyId string = vmBackupPolicy.id

// ARM resource ID of the file share backup policy; referenced when enrolling
// Azure File Shares into protection in the storage module
output filePolicyId string = fileBackupPolicy.id
