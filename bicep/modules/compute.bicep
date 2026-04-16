// ============================================================================
// Compute — VM Scale Sets for web + app tiers with extensions
// AZ-104 scope: Virtual Machines, Scale Sets, Extensions, Autoscale
// This module provisions the compute layer of a two-tier architecture:
//   - Web tier VMSS (internet-facing, nginx, behind a public LB)
//   - App tier VMSS (internal, behind an internal LB)
// Both scale sets use availability zones, rolling upgrades, and automatic
// repairs — all key HA/DR patterns tested in the AZ-104 exam.
// ============================================================================

// -- Parameters --------------------------------------------------------------
// Parameters are declared without defaults (except credentials) so that the
// caller (main.bicep / pipeline) must supply every value explicitly.
// This prevents accidental use of wrong defaults across environments.

param location string
// Azure region for all resources in this module (e.g. 'eastus2').
// Passing location as a param rather than hard-coding it follows ARM best
// practice and is required when deploying to multiple regions.

param environment string
// Deployment environment token: 'prod' | 'staging' | 'dev'.
// Drives SKU selection and instance counts via conditional variables below.
// AZ-104: understand how environment-aware sizing controls cost and SLA.

param orgPrefix string
// Short organisation prefix used to build globally unique, policy-compliant
// resource names (e.g. 'contoso'). Combined with resource type and env token
// to produce names like 'contoso-vmss-web-prod'.

param tags object
// Metadata object applied to every resource for governance.
// AZ-104: Azure Policy can enforce required tags; tagging is a cost-management
// and compliance requirement covered in the exam.

param webSubnetId string
// Full resource ID of the subnet dedicated to web-tier VMs.
// Placing web VMs in their own subnet allows NSG rules to control inbound
// HTTP/HTTPS and restrict east-west traffic to the app tier.

param appSubnetId string
// Full resource ID of the subnet dedicated to app-tier VMs.
// Isolation from the web subnet enforces defence-in-depth: app VMs are never
// directly reachable from the internet — only from web-tier VMs.

param webLbBackendPoolId string
// Resource ID of the backend address pool on the public-facing Load Balancer
// that fronts the web tier. VMSS instances register here automatically;
// the LB distributes inbound traffic across healthy instances.

param appLbBackendPoolId string
// Resource ID of the backend address pool on the internal Load Balancer
// that fronts the app tier. Keeps app-tier traffic off the public internet.

param logAnalyticsWorkspaceId string
// Resource ID of the central Log Analytics workspace.
// Diagnostic extensions and Azure Monitor agents ship VM metrics and logs here.
// AZ-104: Monitor is a key topic — know how workspaces aggregate telemetry.

param keyVaultName string
// Name of the Azure Key Vault that stores secrets referenced by this module
// (e.g. admin credentials, certificates).
// AZ-104: Key Vault integration removes hardcoded secrets from IaC templates.

param keyVaultResourceGroup string
// Resource group that hosts the Key Vault above.
// Needed when the vault lives in a shared-services RG separate from compute.

@secure()
// @secure() marks the param as sensitive: Bicep suppresses the value in
// deployment history and logs. Required for any credential passed at deploy time.
@description('Admin username — injected at deploy time, never hardcoded')
param adminUsername string = 'azureadmin'
// Default provided only for convenience in dev/demo; override in production.
// AZ-104: never embed credentials in source code — use Key Vault references or
// deployment-time injection via pipelines.

@secure()
// @secure() ensures the password is never written to ARM deployment outputs
// or state files in plain text.
@description('Admin password — use Key Vault reference in production')
param adminPassword string
// No default — the caller must supply this value.
// In a production pipeline this would be: adminPassword: getSecret(keyVaultName, 'vm-admin-password')

// -- Variables ---------------------------------------------------------------
// Variables are resolved at deploy time and cannot be overridden by callers.
// They are ideal for logic that should be consistent within the module.

var vmSku = environment == 'prod' ? 'Standard_D2s_v5' : 'Standard_B2s'
// Prod: Standard_D2s_v5 — 2 vCPU, 8 GB RAM, Premium SSD support, burstable
//       network; suitable for sustained production workloads.
// Non-prod: Standard_B2s — burstable, lower cost, fine for dev/staging load.
// AZ-104: know VM size families (B-series for burstable, D-series for
// general-purpose, E-series for memory-optimised) and their use cases.

var instanceCount = environment == 'prod' ? 3 : 2
// Minimum running instances per scale set at deploy time.
// Three instances in prod means the workload survives the loss of one
// availability zone (one instance per zone) — a core HA requirement.
// Two instances in non-prod balances cost with basic redundancy.

// -- Web Tier VMSS -----------------------------------------------------------
// The web tier is the internet-facing layer. It runs nginx, is attached to the
// public Load Balancer backend pool, and lives in the web subnet.
// AZ-104: VMSS is the recommended compute pattern for scalable, zone-redundant
// stateless workloads. Understand VMSS vs. standalone VMs for the exam.

resource webVmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  // Name follows the org-resourcetype-role-env convention for easy filtering
  // in the portal, Azure CLI, and cost management reports.
  name: '${orgPrefix}-vmss-web-${environment}'

  location: location
  // Resources should always be co-located with their dependent resources
  // (subnets, LBs) to avoid cross-region latency and egress charges.

  tags: tags
  // Tags propagate from the caller, ensuring consistent governance metadata
  // across all resources in the deployment.

  sku: {
    name: vmSku
    // VM size — controlled by the vmSku variable above for env parity.

    tier: 'Standard'
    // 'Standard' is the production-grade compute tier; 'Basic' is deprecated.
    // AZ-104: Basic VMs lack SLA guarantees and premium disk support.

    capacity: instanceCount
    // Number of VM instances to deploy initially.
    // Autoscale (below) will adjust this at runtime based on CPU metrics.
  }

  zones: ['1', '2', '3']
  // Spread instances across all three availability zones in the region.
  // AZ-104: Availability Zones provide 99.99% VM SLA (vs. 99.95% for Availability Sets).
  // Each zone is an independent physical datacenter with separate power/cooling.
  // With 3 zones, the workload survives a full zone failure without downtime.

  properties: {

    overprovision: false
    // When true, Azure spins up extra instances and deletes them after the
    // target count is healthy (faster scale-out at no extra charge).
    // Disabled here because the CustomScript extension is idempotent and we
    // want precise instance counts visible in the portal during demos.
    // AZ-104: understand the trade-off — overprovisioning speeds scale-out
    // but can cause duplicate extension executions if not handled.

    upgradePolicy: {
      mode: 'Rolling'
      // Rolling upgrades replace instances in batches, keeping a portion
      // healthy throughout. Alternatives:
      //   Manual  — no automatic replacement; operator controls each instance.
      //   Automatic — replaces all instances simultaneously (causes downtime).
      // AZ-104: Rolling is the exam-recommended mode for zero-downtime deploys.

      rollingUpgradePolicy: {
        maxBatchInstancePercent: 33
        // At most 33 % of instances are taken offline in a single upgrade batch.
        // With 3 instances (one per zone), this equals 1 instance per batch —
        // ensuring 2 instances always handle traffic during an upgrade.

        maxUnhealthyInstancePercent: 33
        // If more than 33 % of all instances are unhealthy at any point,
        // the rolling upgrade is paused or cancelled to prevent a cascading
        // outage. Acts as a safety circuit-breaker.

        maxUnhealthyUpgradedInstancePercent: 33
        // Like the above but scoped to instances that have already been
        // upgraded in this batch. Catches regressions introduced by the
        // new image/config before the next batch starts.

        pauseTimeBetweenBatches: 'PT10S'
        // ISO 8601 duration: wait 10 seconds between batches.
        // Gives the load balancer health probes time to confirm upgraded
        // instances are passing health checks before continuing.
      }
    }

    automaticRepairsPolicy: {
      enabled: true
      // When enabled, Azure monitors the Application Health extension signal
      // on each instance and automatically replaces unhealthy VMs.
      // AZ-104: this is the VMSS equivalent of auto-healing in App Service —
      // it reduces MTTR without manual intervention.

      gracePeriod: 'PT30M'
      // ISO 8601 duration: allow a newly created or updated instance 30 minutes
      // to become healthy before the repair policy considers it broken.
      // Prevents premature replacement of instances still running startup scripts.
    }

    virtualMachineProfile: {
    // The profile defines the blueprint applied to every instance in the scale set.
    // Changes to the profile are applied via the upgrade policy above.

      osProfile: {
      // OS-level configuration applied at instance provisioning time.

        computerNamePrefix: 'web'
        // Each instance hostname will be 'web000000', 'web000001', etc.
        // The prefix must be ≤ 9 characters for Linux (OS limit: 15 chars total).

        adminUsername: adminUsername
        // Injected from the @secure() param — never literal in source code.
        // AZ-104: local admin accounts on VMs should be managed via Azure AD
        // or Privileged Identity Management in production.

        adminPassword: adminPassword
        // Injected from the @secure() param. In a mature pipeline this would
        // reference a Key Vault secret via getSecret() to keep it out of
        // pipeline logs entirely.

        linuxConfiguration: {
          disablePasswordAuthentication: false
          // Password auth is left enabled here for demo/portfolio accessibility.
          // AZ-104 best practice: set to true and use SSH public keys stored
          // in Key Vault or Azure AD SSH extension for password-less access.

          provisionVMAgent: true
          // The Azure VM Agent (walinuxagent) is mandatory for VM extensions,
          // boot diagnostics, and Azure Monitor. Must be true for any managed VM.
          // AZ-104: the VM Agent is the communication channel between the Azure
          // fabric and the guest OS — extensions cannot run without it.

          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            // Azure orchestrates OS patching, scheduling reboots during
            // maintenance windows. Alternatives:
            //   ImageDefault — OS-level unattended-upgrades manages patches.
            //   Manual       — operator applies patches; no automation.
            // AZ-104: AutomaticByPlatform integrates with Azure Update Manager.

            assessmentMode: 'AutomaticByPlatform'
            // Azure periodically scans for missing patches and reports compliance
            // in Azure Update Manager / Security Center without applying them.
            // Enables proactive visibility into patch status across the fleet.
          }
        }
      }

      storageProfile: {
      // Defines the OS image and disk configuration for each VM instance.

        imageReference: {
          publisher: 'Canonical'
          // The official Ubuntu publisher on Azure Marketplace.
          // AZ-104: always use Marketplace images with a known publisher to
          // ensure Microsoft-supported, regularly patched base images.

          offer: '0001-com-ubuntu-server-jammy'
          // Ubuntu Server 22.04 LTS (Jammy Jellyfish) — the current LTS release.
          // LTS images have 5-year support windows, reducing patching urgency.

          sku: '22_04-lts-gen2'
          // Gen2 images use UEFI boot (vs. BIOS for Gen1), required for
          // Trusted Launch (vTPM, Secure Boot) and supported by all v5 VM sizes.
          // AZ-104: Generation 2 VMs support features like UEFI and NVMe disks.

          version: 'latest'
          // Always pull the most recently patched image at deploy time.
          // For reproducible deployments in CI/CD, pin to a specific version
          // (e.g. '22.04.202403010') — 'latest' is acceptable for demos.
        }

        osDisk: {
          createOption: 'FromImage'
          // Provision the OS disk by cloning the selected Marketplace image.
          // Required when deploying from an image reference (vs. 'Attach' for
          // a pre-existing disk, or 'Empty' for a blank data disk).

          caching: 'ReadWrite'
          // ReadWrite caching maximises OS disk read and write performance by
          // using the VM host cache. Appropriate for OS disks; use 'ReadOnly'
          // for data disks serving read-heavy workloads.

          managedDisk: {
            storageAccountType: 'Premium_LRS'
            // Premium SSD (Locally Redundant Storage) — three synchronous copies
            // within a single datacenter / zone.
            // AZ-104: Premium SSD is required for production IOPS SLAs.
            // For OS disks of web servers Premium_LRS is the minimum recommended.
            // Standard_LRS costs less but has no IOPS SLA — use for dev/test only.
          }
        }
      }

      networkProfile: {
      // Defines the virtual NIC configuration attached to every VM instance.

        networkInterfaceConfigurations: [
          {
            name: 'web-nic'
            // NIC configuration name — used internally by VMSS; does not appear
            // as a standalone NIC resource in the portal.

            properties: {
              primary: true
              // Marks this as the primary NIC. Each instance can have multiple
              // NICs (for NVA scenarios), but exactly one must be primary.

              enableAcceleratedNetworking: true
              // Bypasses the host vSwitch and connects the VM directly to the
              // physical NIC via SR-IOV. Reduces latency and CPU overhead.
              // AZ-104: supported on D/E/F v3+ series and most v5 sizes.
              // Improves throughput significantly for network-intensive workloads.

              ipConfigurations: [
                {
                  name: 'web-ipconfig'
                  // Name for this IP configuration on the NIC. Multiple
                  // ipConfigurations allow multiple private IPs per NIC.

                  properties: {
                    primary: true
                    // Primary IP configuration used for outbound traffic and
                    // for Load Balancer health probe association.

                    subnet: { id: webSubnetId }
                    // Attach this NIC to the web subnet passed from the caller.
                    // VMSS instances receive a private IP from this subnet's
                    // address space automatically via DHCP.

                    loadBalancerBackendAddressPools: [
                      { id: webLbBackendPoolId }
                      // Register every scale set instance in the LB backend pool.
                      // The Load Balancer distributes inbound traffic across all
                      // healthy members using the configured load balancing rules.
                      // AZ-104: understand LB SKUs — Standard LB supports zones
                      // and is required when VMSS spans availability zones.
                    ]
                  }
                }
              ]
            }
          }
        ]
      }

      extensionProfile: {
      // Extensions are lightweight agents installed inside the VM guest OS.
      // They run after the VM is provisioned and are managed by the VM Agent.
      // AZ-104: know the common extensions — CustomScript, DSC, MMA/AMA,
      // AADSSHLoginForLinux, DependencyAgent, ApplicationHealthLinux.

        extensions: [
          {
            name: 'InstallNginx'
            // CustomScript extension executes an arbitrary shell command inside
            // each VM instance. Used here to install and configure nginx.

            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              // The publisher namespace for Azure-supported Linux extensions.

              type: 'CustomScript'
              // CustomScript is the most flexible extension — runs any
              // script or command with the VM's local root context.

              typeHandlerVersion: '2.1'
              // Major.minor version of the extension handler. Azure auto-
              // applies minor patches when autoUpgradeMinorVersion is true.

              autoUpgradeMinorVersion: true
              // Allow Azure to upgrade to newer minor versions of the extension
              // handler automatically. Does NOT affect the script itself.

              settings: {
                commandToExecute: 'apt-get update && apt-get install -y nginx && systemctl enable nginx && echo "healthy" > /var/www/html/health'
                // 1. apt-get update       — refresh package index.
                // 2. apt-get install nginx — install the web server.
                // 3. systemctl enable nginx — ensure nginx starts on reboot.
                // 4. echo "healthy" > /health — create the health endpoint
                //    that the Application Health extension (below) polls.
                //    AZ-104: health endpoints are required for rolling upgrades
                //    and automatic repairs to function correctly.
              }
            }
          }
          {
            name: 'HealthExtension'
            // Application Health extension is the signal source for:
            //   - Automatic repairs policy (replaces unhealthy instances).
            //   - Rolling upgrade gating (pauses if unhealthy % is exceeded).
            // AZ-104: this extension is a prerequisite for both features above.

            properties: {
              publisher: 'Microsoft.ManagedServices'
              // Publisher namespace for the Application Health extension.

              type: 'ApplicationHealthLinux'
              // Linux variant of the health extension. Windows variant is
              // 'ApplicationHealthWindows' — same parameters, different binary.

              typeHandlerVersion: '1.0'
              // Current stable version of the health extension.

              autoUpgradeMinorVersion: true
              // Auto-patch the extension handler itself on minor releases.

              settings: {
                protocol: 'http'
                // Protocol used to issue the health probe from inside the VM.
                // Use 'https' if nginx is configured with TLS termination.

                port: 80
                // Port to probe — must match the nginx listener.

                requestPath: '/health'
                // URI path created by the CustomScript extension above.
                // Returns HTTP 200 when nginx is up, signalling a healthy state
                // to the VMSS orchestrator.
              }
            }
          }
        ]
      }

      diagnosticsProfile: {
      // Controls VM-level diagnostics that help with troubleshooting boot
      // failures and OS-level events.

        bootDiagnostics: {
          enabled: true
          // Captures the serial console output and a screenshot of each VM
          // instance during boot. Stored in a managed storage account.
          // AZ-104: boot diagnostics is the primary tool for diagnosing VMs
          // that fail to start or are stuck at the boot screen.
          // Without a storageUri, Azure uses a platform-managed account
          // (recommended — no storage account to manage or secure).
        }
      }
    }
  }
}

// -- App Tier VMSS -----------------------------------------------------------
// The app tier hosts the business-logic layer. It is only reachable from the
// web tier via the internal Load Balancer — never directly from the internet.
// This enforces a classic DMZ / layered security model.
// AZ-104: understand the difference between public Standard LB (internet-
// facing) and internal Standard LB (private VNet routing only).

resource appVmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${orgPrefix}-vmss-app-${environment}'
  // Same naming convention as web tier — 'app' role token distinguishes it.

  location: location
  // Co-located with webVmss for low-latency VNet-internal communication
  // between the web and app tiers.

  tags: tags
  // Consistent tags enable cost allocation per tier in Cost Management +
  // Billing; useful for chargeback models in enterprise environments.

  sku: {
    name: vmSku
    // Same variable as web tier — both tiers use the same VM size family.
    // In production you may choose a memory-optimised SKU (E-series) if
    // the app runtime (JVM) requires more RAM than CPU.

    tier: 'Standard'
    // Production compute tier — same reasoning as web tier.

    capacity: instanceCount
    // Initial instance count driven by the same env-aware variable.
    // App tier autoscale is omitted here (add a separate autoscale resource
    // if the app tier has independent CPU profiles from the web tier).
  }

  zones: ['1', '2', '3']
  // Zone redundancy mirrors the web tier. Because the web tier spans all
  // three zones, the app tier must too — otherwise a zone failure in the
  // app tier would break the whole request path even if web tier survives.
  // AZ-104: zone alignment across tiers is a critical design requirement.

  properties: {

    overprovision: false
    // Same reasoning as web tier. Disabled for demo clarity.

    upgradePolicy: {
      mode: 'Rolling'
      // Rolling upgrades on the app tier prevent downtime during JDK/app
      // updates. The same batch percentages ensure at least 2 of 3 instances
      // stay up throughout any upgrade operation.

      rollingUpgradePolicy: {
        maxBatchInstancePercent: 33
        // One instance per batch (33 % of 3). Same logic as web tier.

        maxUnhealthyInstancePercent: 33
        // Circuit-breaker: halt the upgrade if 1+ instances are unhealthy
        // before the batch even starts.

        maxUnhealthyUpgradedInstancePercent: 33
        // Circuit-breaker for post-upgrade health: halt if the newly
        // upgraded instance fails its health check.

        pauseTimeBetweenBatches: 'PT10S'
        // 10-second pause between batches. The internal LB health probe
        // interval is typically 5 s, so 10 s allows at least two probe
        // cycles to confirm the upgraded instance is healthy.
      }
    }

    automaticRepairsPolicy: {
      enabled: true
      // Automatic repairs is especially valuable on the app tier where a
      // JVM OOM or deadlock may leave the process running (so the VM appears
      // up) but the application is unresponsive — the health extension
      // catches this where standard VM monitoring would not.

      gracePeriod: 'PT30M'
      // 30-minute grace period allows the JDK and app runtime to fully
      // initialise before the repair policy evaluates instance health.
      // JVM startup is typically slower than nginx — the grace period
      // should be tuned to the actual startup time of the workload.
    }

    virtualMachineProfile: {

      osProfile: {
        computerNamePrefix: 'app'
        // Hostnames will be 'app000000', 'app000001', etc.
        // Distinct prefix from 'web' aids log correlation and monitoring.

        adminUsername: adminUsername
        // Same admin account across both tiers; centralised via @secure() param.

        adminPassword: adminPassword
        // Same credential management approach as web tier.

        linuxConfiguration: {
          disablePasswordAuthentication: false
          // Matches web tier setting for demo consistency.
          // AZ-104 exam tip: in real deployments, disable passwords and
          // use SSH keys or Azure AD login (AADSSHLoginForLinux extension).

          provisionVMAgent: true
          // Required for all extensions and Azure Monitor integration.

          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            // Azure-managed patching ensures the app tier is kept up to date
            // with OS security patches without operator intervention.
            // Patches are applied in coordination with maintenance windows
            // to minimise disruption to running JVM workloads.

            assessmentMode: 'AutomaticByPlatform'
            // Continuous patch-compliance assessment feeds into Azure
            // Security Center / Defender for Cloud recommendations.
            // AZ-104: Defender for Cloud is covered in the Security domain.
          }
        }
      }

      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
          // Identical image to web tier — single image lineage simplifies
          // patching and security scanning. If the app tier needs a different
          // OS (e.g. RHEL), change the publisher/offer/sku here only.
        }

        osDisk: {
          createOption: 'FromImage'
          // Create the OS disk from the Marketplace image above.

          caching: 'ReadWrite'
          // ReadWrite host-cache for OS disk performance — same as web tier.
          // If the app tier writes heavy logs to the OS disk, consider
          // adding a separate data disk with 'None' caching to avoid
          // cache invalidation overhead.

          managedDisk: {
            storageAccountType: 'Premium_LRS'
            // Premium SSD for the app tier OS disk. JVM applications benefit
            // from low-latency disk I/O during startup (class loading) and
            // when heap snapshots / core dumps are written to disk.
          }
        }
      }

      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'app-nic'
            // App tier NIC config — no public IP, no public LB association.
            // Instances are only reachable via the internal LB from the
            // web subnet (controlled by NSG rules on the app subnet).

            properties: {
              primary: true
              // Single NIC per instance for this tier. Multi-NIC would be
              // needed for NVA or dual-homed scenarios.

              enableAcceleratedNetworking: true
              // SR-IOV enabled on the app tier for low-latency communication
              // with the web tier. Reduces TCP round-trip time on the
              // internal VNet path between tiers.

              ipConfigurations: [
                {
                  name: 'app-ipconfig'
                  properties: {
                    primary: true
                    // Primary IP config — receives a private IP from the
                    // app subnet's address range.

                    subnet: { id: appSubnetId }
                    // Place this NIC in the app subnet (isolated from web subnet).
                    // The NSG on the app subnet should DENY inbound from
                    // anywhere except the web subnet and management sources.
                    // AZ-104: NSG association is at the subnet level here —
                    // a single NSG rule change protects all app tier instances.

                    loadBalancerBackendAddressPools: [
                      { id: appLbBackendPoolId }
                      // Register with the internal LB backend pool.
                      // Web-tier VMs send traffic to the internal LB frontend
                      // IP; the LB distributes it across healthy app instances.
                      // AZ-104: internal Standard LB does not require a public
                      // IP and supports zone-redundant frontends.
                    ]
                  }
                }
              ]
            }
          }
        ]
      }

      extensionProfile: {
        extensions: [
          {
            name: 'InstallAppRuntime'
            // CustomScript extension installs the Java Development Kit (JDK)
            // needed to run the application tier workload.

            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              // Same publisher as web tier CustomScript — Microsoft.Azure.Extensions
              // covers the CustomScript extension for Linux VMs.

              type: 'CustomScript'
              // CustomScript runs the commandToExecute as root inside the VM.
              // For production, consider pulling scripts from Azure Blob Storage
              // or a Git repo via the 'fileUris' setting instead of embedding
              // commands inline — easier to version, audit, and rotate.

              typeHandlerVersion: '2.1'
              // Extension handler version — same as web tier for consistency.

              autoUpgradeMinorVersion: true
              // Allow Azure to patch the extension handler automatically.

              settings: {
                commandToExecute: 'apt-get update && apt-get install -y default-jdk && echo "App tier initialized"'
                // 1. apt-get update           — refresh package index.
                // 2. apt-get install default-jdk — install OpenJDK (Java runtime + compiler).
                //    'default-jdk' resolves to the distro-recommended JDK version
                //    (OpenJDK 11 on Ubuntu 22.04). Pin a specific version in production
                //    (e.g. openjdk-17-jdk) for reproducibility.
                // 3. echo "App tier initialized" — simple signal in stdout for
                //    extension execution logs; confirms the script completed.
                // NOTE: A production deployment would also deploy the application
                // JAR/WAR, configure systemd unit files, and set env variables
                // via this command or a downloaded script.
              }
            }
          }
          // NOTE: No HealthExtension is defined for the app tier in this template.
          // If automaticRepairsPolicy is enabled (it is), a health extension or
          // load balancer health probe is required for the repair signal.
          // AZ-104 action: add ApplicationHealthLinux here, probing the app's
          // health endpoint (e.g. /actuator/health on port 8080 for Spring Boot).
        ]
      }

      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
          // Boot diagnostics on the app tier is critical: JVM OOM errors and
          // kernel panics are surfaced in the serial console output.
          // AZ-104: always enable boot diagnostics — it is free (managed storage)
          // and is often the only way to diagnose a non-booting VM.
        }
      }
    }
  }
}

// -- Autoscale: Web Tier -----------------------------------------------------
// Azure Monitor Autoscale adjusts the VMSS instance count at runtime based on
// metric thresholds. This is a separate ARM resource linked to the VMSS — it
// does NOT modify the VMSS capacity property directly.
// AZ-104: Autoscale is covered in the Monitor domain. Know the difference
// between metric-based rules (below), schedule-based rules, and predictive
// autoscale. Also understand that Autoscale acts on the VMSS capacity, which
// then triggers the upgradePolicy to provision or deprovision instances.

resource webAutoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${orgPrefix}-autoscale-web-${environment}'
  // Name follows org naming convention. Only one autoscale setting per resource
  // is supported — if this resource already exists it will be updated in place.

  location: location
  // Autoscale settings are a regional resource — must match the VMSS region.

  tags: tags
  // Tag the autoscale resource for cost and governance consistency.

  properties: {

    enabled: true
    // Master switch for autoscale. When false, the profile rules are ignored
    // and the VMSS remains at its current capacity indefinitely.
    // AZ-104: disabling autoscale is useful during incident investigations to
    // prevent unwanted scale-in while diagnosing a performance issue.

    targetResourceUri: webVmss.id
    // The resource ID of the VMSS this autoscale setting controls.
    // Bicep resolves this symbolic reference at compile time — no hard-coding.

    profiles: [
    // Profiles define scaling behaviour for different time windows or conditions.
    // Multiple profiles allow different rules for business hours vs. off-hours.
    // The 'Default' profile applies when no schedule-based profile is active.

      {
        name: 'DefaultProfile'
        // Named 'Default' by convention — Azure requires at least one profile
        // and uses the first matching one. Additional profiles (e.g.
        // 'WeekendProfile') can override this on a schedule.

        capacity: {
          minimum: '2'
          // Never scale below 2 instances — ensures the web tier survives a
          // single instance failure even at off-peak hours.
          // AZ-104: minimum >= 2 is the exam-recommended baseline for any
          // production workload to maintain availability.

          maximum: environment == 'prod' ? '10' : '4'
          // Prod: up to 10 instances — supports significant traffic spikes
          //       while capping runaway scaling costs.
          // Non-prod: capped at 4 to control lab/staging costs.
          // AZ-104: always set a maximum to prevent cost overruns from a
          // metric spike caused by a DoS attack or runaway process.

          default: string(instanceCount)
          // The capacity Azure falls back to if metric data is unavailable.
          // Matches the initial deployment count so a metric gap does not
          // trigger unexpected scaling. Must be a string (ARM requirement).
        }

        rules: [
        // Rules define the metric conditions and resulting scale actions.
        // Each rule has a trigger (metric condition) and an action (scale step).
        // AZ-104: scale-out and scale-in rules should be paired — if you only
        // define scale-out, the instance count will never decrease.

          {
            // SCALE-OUT RULE: add an instance when average CPU > 75 % for 5 min.
            metricTrigger: {
              metricName: 'Percentage CPU'
              // Platform metric emitted by every Azure VM at no extra cost.
              // AZ-104: know the common VMSS metrics — CPU %, Network In/Out,
              // Disk Read/Write Bytes. Custom metrics require Azure Monitor Agent.

              metricResourceUri: webVmss.id
              // Source resource for the metric. Points to the VMSS so the
              // metric is aggregated across all instances (not per-instance).

              timeGrain: 'PT1M'
              // ISO 8601: metric granularity — one data point per minute.
              // The finest available grain for most platform metrics.

              statistic: 'Average'
              // How to aggregate metric values across all instances within
              // a single timeGrain interval.
              // Options: Average | Min | Max | Sum | Count
              // Average is appropriate for CPU % — it reflects fleet-wide load.

              timeWindow: 'PT5M'
              // ISO 8601: evaluation window — assess the last 5 minutes of data.
              // A shorter window reacts faster but may trigger on transient spikes.
              // A longer window is more stable but slower to respond to load.

              timeAggregation: 'Average'
              // How to aggregate the statistic values across the timeWindow.
              // Average over 5 minutes of 1-minute averages smooths out spikes.

              operator: 'GreaterThan'
              // Trigger the rule when the aggregated metric EXCEEDS the threshold.
              // Use 'GreaterThanOrEqual' if the threshold value itself should trigger.

              threshold: 75
              // Scale out at 75 % average CPU — leaves headroom before saturation
              // (typically 100 % CPU causes request queuing and latency spikes).
              // AZ-104: threshold selection is workload-dependent; 70-80 % is a
              // common starting point for CPU-bound web workloads.
            }

            scaleAction: {
              direction: 'Increase'
              // Increase instance count (scale out). Use 'Decrease' for scale-in.

              type: 'ChangeCount'
              // Add/remove a fixed number of instances.
              // Alternatives: PercentChangeCount (relative) | ExactCount (set absolute).

              value: '1'
              // Add 1 instance per trigger. Conservative step size avoids
              // over-provisioning when a spike is brief.
              // For faster response to sudden load surges, increase to '2' or '3'.

              cooldown: 'PT5M'
              // ISO 8601: wait 5 minutes after a scale action before allowing
              // another scale-out. Prevents rapid oscillation ('flapping') while
              // new instances are still initialising.
              // AZ-104: cooldown periods are critical — too short causes flapping,
              // too long leaves the service under-provisioned during sustained load.
            }
          }

          {
            // SCALE-IN RULE: remove an instance when average CPU < 25 % for 10 min.
            // Scale-in uses a longer timeWindow and lower threshold than scale-out
            // to be conservative — it is better to stay slightly over-provisioned
            // than to scale in prematurely and then immediately have to scale out again.
            metricTrigger: {
              metricName: 'Percentage CPU'
              // Same metric as the scale-out rule.

              metricResourceUri: webVmss.id
              // Same VMSS resource.

              timeGrain: 'PT1M'
              // Same 1-minute granularity.

              statistic: 'Average'
              // Average CPU across all instances.

              timeWindow: 'PT10M'
              // Longer window for scale-in (10 min vs. 5 min for scale-out).
              // AZ-104 best practice: scale-in rules should use a longer
              // evaluation window to avoid removing instances prematurely
              // during a brief CPU dip between traffic bursts.

              timeAggregation: 'Average'
              // Average across the 10-minute window.

              operator: 'LessThan'
              // Trigger when CPU drops BELOW the threshold.

              threshold: 25
              // Scale in below 25 % average CPU — conservative lower bound.
              // The gap between 25 % (scale-in) and 75 % (scale-out) is the
              // steady-state operating band where no scaling occurs.
            }

            scaleAction: {
              direction: 'Decrease'
              // Remove an instance (scale in).

              type: 'ChangeCount'
              // Remove a fixed count.

              value: '1'
              // Remove 1 instance at a time — gradual scale-in protects against
              // a false positive caused by a brief CPU drop.

              cooldown: 'PT10M'
              // 10-minute cooldown after scale-in — longer than scale-out
              // cooldown to further dampen oscillation. The scale set must
              // stabilise at the new (lower) count before another decrease
              // is permitted.
              // AZ-104: unequal cooldowns (shorter for out, longer for in)
              // are a well-known autoscale design pattern for web workloads.
            }
          }
        ]
      }
    ]
  }
}

// -- Outputs -----------------------------------------------------------------
// Outputs surface resource IDs back to the caller (main.bicep or a pipeline).
// They allow dependent modules to reference these resources without hard-coding
// IDs and without duplicating resource declaration logic.
// AZ-104: understand ARM template / Bicep outputs — they are the primary
// mechanism for chaining modules and passing values between deployment stages.

output webVmssId string = webVmss.id
// Full resource ID of the web tier VMSS.
// Consumers: monitoring module (to scope diagnostic settings or alerts),
// autoscale module (if extracted), policy assignments, or CI/CD pipelines
// that need the resource ID for post-deployment validation.

output appVmssId string = appVmss.id
// Full resource ID of the app tier VMSS.
// Same use cases as webVmssId — allows the calling module to wire up
// monitoring, alerts, or additional extensions without re-querying Azure.
