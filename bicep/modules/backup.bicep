// ============================================================================
// Backup & Recovery — Recovery Services Vault, VM backup policies, file recovery
// AZ-104 Domain: critical for exam and production
// ============================================================================

param location string
param environment string
param orgPrefix string
param tags object
param logAnalyticsWorkspaceId string

// ── Recovery Services Vault ────────────────────────────────────────────────

resource rsVault 'Microsoft.RecoveryServices/vaults@2023-06-01' = {
  name: '${orgPrefix}-rsv-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    securitySettings: {
      softDeleteSettings: {
        softDeleteState: 'Enabled'
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

// ── Backup Policy: Daily VM Backup ─────────────────────────────────────────

resource vmBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  parent: rsVault
  name: 'policy-vm-daily'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: ['2024-01-01T02:00:00Z']    // 2 AM UTC
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          count: environment == 'prod' ? 30 : 7
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: ['Sunday']
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          count: environment == 'prod' ? 12 : 4
          durationType: 'Weeks'
        }
      }
      monthlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        retentionScheduleWeekly: {
          daysOfTheWeek: ['Sunday']
          weeksOfTheMonth: ['First']
        }
        retentionTimes: ['2024-01-01T02:00:00Z']
        retentionDuration: {
          count: environment == 'prod' ? 12 : 3
          durationType: 'Months'
        }
      }
    }
    timeZone: 'Eastern Standard Time'
  }
}

// ── Backup Policy: File Share Backup ───────────────────────────────────────

resource fileBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  parent: rsVault
  name: 'policy-fileshare-daily'
  properties: {
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: ['2024-01-01T03:00:00Z']
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: ['2024-01-01T03:00:00Z']
        retentionDuration: {
          count: 30
          durationType: 'Days'
        }
      }
    }
    timeZone: 'Eastern Standard Time'
  }
}

// ── Vault Diagnostics ─────────────────────────────────────────────────────

resource rsvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: rsVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output vaultName string = rsVault.name
output vaultId string = rsVault.id
output vmPolicyId string = vmBackupPolicy.id
output filePolicyId string = fileBackupPolicy.id
