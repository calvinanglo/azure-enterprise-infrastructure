// ============================================================================
// Disk Management — Managed disks, snapshots, disk encryption, shared image
// AZ-104 Domain: Deploy and manage Azure compute resources
// Managed disks are the recommended Azure storage type for VM OS and data disks.
// Unlike unmanaged disks (page blobs), managed disks are fully managed by Azure:
// no storage account capacity planning, automatic fault domain placement, and
// simplified snapshot/restore operations.
// ============================================================================

// -- Parameters ---------------------------------------------------------------

// Azure region where all disk resources are deployed. Managed disks must be in
// the same region as the VMs they are attached to.
param location string

// Deployment environment (dev / staging / prod) — drives SKU and performance
// tier selection for cost vs. performance trade-offs
param environment string

// Short organization prefix used in all resource names
param orgPrefix string

// Resource tags applied to every resource for cost management and governance
param tags object

// ── Managed Data Disk (attachable to VMs) ─────────────────────────────────
// A standalone managed disk that can be attached to one or more VMs as a
// data disk. Created in advance here so it exists before VM provisioning
// and can be pre-populated with data if needed.

resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  // Naming convention: <prefix>-disk-<purpose>-<usage>-<environment>
  name: '${orgPrefix}-disk-data-shared-${environment}'
  location: location
  tags: tags
  sku: {
    // Premium_LRS for prod: SSD-backed, low latency, high IOPS (up to 500 IOPS/GB).
    //   Best for production databases, transactional workloads, and OS disks.
    // StandardSSD_LRS for non-prod: balanced SSD with lower cost than Premium.
    //   Suitable for dev/test workloads where peak IOPS are not critical.
    // Other options: Standard_LRS (HDD, lowest cost), UltraSSD_LRS (extreme IOPS)
    name: environment == 'prod' ? 'Premium_LRS' : 'StandardSSD_LRS'
  }
  properties: {
    // diskSizeGB: provisioned capacity in gigabytes. For Premium_LRS, this also
    // determines the IOPS and throughput tier (P10 = 128 GB = 500 IOPS / 100 MBps)
    diskSizeGB: 128
    creationData: {
      // 'Empty' creates a blank, unformatted disk. The VM OS must initialize and
      // format the disk (e.g. mkfs on Linux, Disk Management on Windows) before use.
      // Other options: 'FromImage' (from gallery image), 'Copy' (from another disk/snapshot)
      createOption: 'Empty'
    }
    encryption: {
      // 'EncryptionAtRestWithPlatformKey' (PMK): Azure manages the encryption keys
      // in its own Key Vault. Data is encrypted at rest with no customer action required.
      // Alternative: 'EncryptionAtRestWithCustomerKey' (CMK) uses a Disk Encryption Set
      // (DES) that wraps a customer key stored in Azure Key Vault — see commented DES
      // resource below. CMK is required for some compliance frameworks (FedRAMP, etc.)
      type: 'EncryptionAtRestWithPlatformKey'
    }
    // Performance tier controls burst IOPS/throughput independently of disk size.
    // 'P10' matches the 128 GB Premium disk baseline tier (500 IOPS, 100 MBps).
    // Setting tier explicitly allows upgrading to a higher tier (e.g. P30) without
    // resizing the disk. null for non-prod uses the default tier for the disk size.
    tier: environment == 'prod' ? 'P10' : null
    // networkAccessPolicy: 'DenyAll' prevents the disk from being accessed via
    // the disk export/import URL. Disks can only be used when attached to a VM.
    // This is a defense-in-depth control against disk data exfiltration.
    networkAccessPolicy: 'DenyAll'             // No public access to disk
    // publicNetworkAccess: 'Disabled' complements networkAccessPolicy by disabling
    // the public endpoint used for disk export/SAS URL generation entirely
    publicNetworkAccess: 'Disabled'
  }
}

// ── Snapshot of Data Disk ─────────────────────────────────────────────────
// Snapshots are point-in-time copies of a managed disk. Incremental snapshots
// store only the blocks that changed since the last snapshot, dramatically
// reducing storage cost and snapshot creation time compared to full snapshots.
// Use cases: pre-upgrade baselines, DR copies, disk cloning for dev environments.

resource diskSnapshot 'Microsoft.Compute/snapshots@2023-10-02' = {
  // 'baseline' suffix indicates this is the initial known-good snapshot taken
  // at deployment time, before any application data is written
  name: '${orgPrefix}-snap-data-${environment}-baseline'
  location: location
  // union() merges the base tags with a SnapshotType tag to classify snapshots
  // for retention policies and cost attribution
  tags: union(tags, { SnapshotType: 'baseline' })
  sku: {
    // Standard_LRS for snapshot storage: cost-effective since snapshots are read-only
    // and accessed infrequently. Premium_LRS is not needed for snapshots.
    name: 'Standard_LRS'
  }
  properties: {
    creationData: {
      // 'Copy' creates the snapshot from an existing disk or snapshot resource
      createOption: 'Copy'
      // sourceResourceId references the data disk defined above; ARM resolves this
      // to the disk's full ARM ID at deployment time
      sourceResourceId: dataDisk.id
    }
    // incremental: true = incremental snapshot. Only blocks changed since the last
    // snapshot are stored, reducing cost significantly for large disks.
    // incremental: false = full snapshot (copy of entire disk, higher cost).
    incremental: true                          // Incremental = cheaper
  }
}

// ── Azure Compute Gallery (Shared Image Gallery) ──────────────────────────
// Azure Compute Gallery (formerly Shared Image Gallery) stores and distributes
// custom VM images (golden images) across regions and subscriptions. Images
// are versioned, can be replicated to multiple regions for resilient VMSS
// deployments, and support TrustedLaunch security features.

resource computeGallery 'Microsoft.Compute/galleries@2022-08-03' = {
  // Gallery names use underscores (hyphens are not supported in gallery names)
  name: '${orgPrefix}_gallery_${environment}'
  location: location
  tags: tags
  properties: {
    // Description is displayed in the portal and in image sharing invitations
    description: 'Golden images for ${environment} VMSS deployments'
  }
}

// ── Image Definition ──────────────────────────────────────────────────────
// An image definition is a logical container within a gallery that describes
// a category of images (OS type, generation, publisher/offer/SKU identifiers).
// Actual image versions (the binary content) are created separately as
// 'Microsoft.Compute/galleries/images/versions' resources after Packer builds.

resource imageDefinition 'Microsoft.Compute/galleries/images@2022-08-03' = {
  // parent links this definition to the compute gallery above
  parent: computeGallery
  // Image definition name used to reference this image category in VMSS deployments
  name: 'ubuntu-web-golden'
  location: location
  tags: tags
  properties: {
    // osType identifies the guest OS family; determines which VM agents and
    // extensions are compatible with images of this definition
    osType: 'Linux'
    // osState: 'Generalized' means the image was sysprep'd (Windows) or
    // waagent-deprovisioned (Linux) to remove machine-specific settings.
    // 'Specialized' images retain hostname, SIDs, and user accounts — used
    // for cloning specific VM states rather than golden image deployments.
    osState: 'Generalized'
    // hyperVGeneration: 'V2' is required for TrustedLaunch (Secure Boot + vTPM)
    // and provides better boot performance. 'V1' is legacy, avoid for new images.
    hyperVGeneration: 'V2'
    identifier: {
      // publisher/offer/SKU form a three-part identifier similar to Azure Marketplace
      // image references. Used for discoverability and policy targeting.
      publisher: orgPrefix           // Organization identifier (e.g. 'contoso')
      offer: 'WebServer'             // Product category (e.g. 'WebServer', 'Database')
      sku: 'Ubuntu2204-Nginx'        // Specific variant (OS version + installed software)
    }
    recommended: {
      // recommended vCPU and memory ranges guide users selecting VM sizes when
      // deploying from this image; enforced as soft limits in the portal
      vCPUs: { min: 2, max: 8 }     // Min 2 vCPU for Nginx worker processes
      memory: { min: 4, max: 32 }   // Min 4 GB RAM for OS + web server + app
    }
    features: [
      {
        // SecurityType: 'TrustedLaunch' enables Secure Boot and vTPM on VMs
        // deployed from this image. Secure Boot prevents rootkit/bootkit attacks;
        // vTPM provides a hardware root of trust for Measured Boot attestation.
        // Requires hyperVGeneration: 'V2'.
        name: 'SecurityType'
        value: 'TrustedLaunch'
      }
    ]
  }
}

// ── Disk Encryption Set (customer-managed keys via Key Vault) ─────────────
// NOTE: Requires Key Vault key — wired in main.bicep after KV deployment
// A Disk Encryption Set (DES) links a Key Vault key to managed disk encryption.
// When a disk references a DES, Azure wraps the disk encryption key (DEK) with
// the customer key from Key Vault (key encryption key / KEK pattern).
// This resource is commented out pending Key Vault key creation in main.bicep;
// uncomment and wire up after the Key Vault module deploys successfully.

// resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
//   name: '${orgPrefix}-des-${environment}'
//   location: location
//   tags: tags
//   // SystemAssigned identity is required so the DES can access Key Vault;
//   // after deployment, grant this identity 'Key Vault Crypto Service Encryption User'
//   // role on the Key Vault (or 'get','wrapKey','unwrapKey' key permissions)
//   identity: { type: 'SystemAssigned' }
//   properties: {
//     activeKey: {
//       // Full versioned URL of the Key Vault key to use as the key encryption key.
//       // Format: https://<vault-name>.vault.azure.net/keys/<key-name>/<version>
//       keyUrl: '<KEY_VAULT_KEY_URL>'
//     }
//     // 'EncryptionAtRestWithCustomerKey' wraps disk DEKs with the specified KV key.
//     // 'EncryptionAtRestWithPlatformAndCustomerKeys' adds double encryption
//     // (both PMK and CMK) for highest security posture.
//     encryptionType: 'EncryptionAtRestWithCustomerKey'
//   }
// }

// ── Outputs ────────────────────────────────────────────────────────────────

// ARM resource ID of the managed data disk; used in VM resource definitions
// to attach this disk as a data disk (under storageProfile.dataDisks[])
output dataDiskId string = dataDisk.id

// ARM resource ID of the baseline snapshot; used in automation scripts that
// clone disks from this snapshot for dev environment provisioning or DR tests
output snapshotId string = diskSnapshot.id

// Short name of the compute gallery; used in image version creation pipelines
// (Packer post-processors) and in VMSS imageReference configuration
output galleryName string = computeGallery.name

// ARM resource ID of the image definition; used in VMSS imageReference to
// reference the latest image version: <definitionId>/versions/latest
output imageDefinitionId string = imageDefinition.id
