# Azure Enterprise Infrastructure Deployment

## Production Multi-Tier Architecture — AZ-104 Scope

Enterprise-grade Azure infrastructure built for a live production environment. This project deploys a fully segmented, monitored, and governed multi-tier architecture using Infrastructure as Code (Bicep), covering every AZ-104 domain at a senior architect level.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        MANAGEMENT GROUP                             │
│                    Azure Policy Assignments                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                     SUBSCRIPTION                                │ │
│  │                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │ │
│  │  │  Hub VNet     │  │  Spoke VNet  │  │  Spoke VNet          │  │ │
│  │  │  10.0.0.0/16  │  │  10.1.0.0/16│  │  10.2.0.0/16         │  │ │
│  │  │              ◄──►│              │  │                       │  │ │
│  │  │  - Firewall   │  │  - Web Tier  │  │  - App Tier          │  │ │
│  │  │  - Bastion    │  │  - NSG       │  │  - NSG               │  │ │
│  │  │  - VPN GW     │  │  - LB (Pub)  │  │  - LB (Internal)    │  │ │
│  │  │  - DNS Zone   │  │  - VMSS      │  │  - VMSS              │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘  │ │
│  │                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │ │
│  │  │  Storage      │  │  Key Vault   │  │  Log Analytics       │  │ │
│  │  │  - Blob       │  │  - Secrets   │  │  - Diagnostics       │  │ │
│  │  │  - Files      │  │  - Keys      │  │  - Alerts            │  │ │
│  │  │  - Lifecycle  │  │  - RBAC      │  │  - Dashboards        │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘  │ │
│  │                                                                  │ │
│  │  ┌──────────────────────────────────────────────────────────┐   │ │
│  │  │                   Entra ID (AAD)                          │   │ │
│  │  │  - Custom RBAC Roles   - Conditional Access              │   │ │
│  │  │  - Security Groups     - PIM (if P2)                     │   │ │
│  │  └──────────────────────────────────────────────────────────┘   │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

---

## AZ-104 Domain Coverage (100%)

| Domain | Components Deployed | Weight |
|--------|-------------------|--------|
| **Identity & Governance** | Entra ID bulk users, static + dynamic groups, administrative units, guest invite, managed identities, custom RBAC roles (3), Azure Policy (5), resource locks, tag enforcement, app registration + OIDC, **Conditional Access (untrusted-IP MFA)**, **custom security attributes (WorkforcePartition)**, **Management Group hierarchy (2-tier)**, **Microsoft Defender for Cloud (Free tier baseline)** | 15-20% |
| **Storage** | Storage account (blob + files), lifecycle management (cool → archive → delete), SAS tokens, stored access policies, AzCopy, key rotation, blob versioning, soft delete, change feed, **Private Endpoint + private DNS zone**, **service endpoints**, **blob immutability (time-based)**, Key Vault (RBAC + purge protection + **Private Endpoint**) | 15-20% |
| **Compute** | VM Scale Sets (2, zonal), autoscale, App Service + deployment slots, Azure Container Instance, Container Registry, managed disks, snapshots, Compute Gallery (golden images), Recovery Services Vault + backup policies (**daily/weekly/monthly/yearly**), custom script extensions, Bastion SSH, **Azure Disk Encryption with Key Vault KEK** | 20-25% |
| **Networking** | Hub-spoke VNets (3), VNet peering (4), Azure Firewall + policy, Bastion, NSGs (3 with **ASG-based rules**), **3 Application Security Groups**, UDRs, public + internal LBs, Azure DNS (public + private, A/CNAME/MX/TXT/alias records), Network Watcher (**Connection Troubleshoot, IP Flow Verify, Next Hop**), NSG flow logs + Traffic Analytics, **VPN Gateway (Basic SKU, P2S)** | 25-30% |
| **Monitoring** | Log Analytics, diagnostic settings on every resource, metric alerts (CPU, availability), log alerts (NSG deny spike), action groups (**email + SMS + webhook + Azure App Push**), VM Insights, KQL queries, **Operations Workbook (4 KQL panels)** | 10-15% |

---

## Project Structure

```
azure-enterprise-infrastructure/
├── bicep/
│   ├── main.bicep                    # Orchestrator — deploys all 13 modules
│   ├── modules/
│   │   ├── entra-identity.bicep      # Managed identities for automation
│   │   ├── identity.bicep            # Custom RBAC roles (3)
│   │   ├── governance.bicep          # Policies (5), locks, tags
│   │   ├── hub-network.bicep         # Hub VNet, Firewall, Bastion, Private DNS
│   │   ├── spoke-network.bicep       # Spoke VNets, peering, NSGs, UDRs
│   │   ├── load-balancers.bicep      # Public + internal load balancers
│   │   ├── dns.bicep                 # Public DNS zone, records, Private DNS
│   │   ├── network-watcher.bicep     # NSG flow logs, Traffic Analytics
│   │   ├── compute.bicep             # VMSS, extensions, autoscale, zones
│   │   ├── app-service.bicep         # Web App, deployment slots, scaling
│   │   ├── containers.bicep          # ACI + ACR
│   │   ├── disks.bicep               # Managed disks, snapshots, image gallery
│   │   ├── storage.bicep             # Blob, files, lifecycle, versioning
│   │   ├── keyvault.bicep            # Key Vault, RBAC, purge protection
│   │   ├── backup.bicep              # Recovery Services, VM + file backup
│   │   └── monitoring.bicep          # Log Analytics, alerts, VM Insights
│   └── parameters/
│       ├── dev.bicepparam            # Dev environment parameters
│       └── prod.bicepparam           # Production parameters
├── scripts/
│   ├── deploy.ps1                    # Full deployment orchestrator
│   ├── validate.ps1                  # Pre-flight validation
│   ├── teardown.ps1                  # Controlled teardown with double-confirm
│   ├── entra-setup.ps1               # Entra ID: bulk users, groups, AUs, RBAC
│   ├── storage-operations.ps1        # SAS, stored policies, AzCopy, key rotation
│   └── network-troubleshoot.ps1      # IP flow verify, next hop, topology
├── data/
│   └── bulk-users.csv                # 10 users for bulk Entra ID creation
├── policies/
│   ├── require-tags.json             # Enforce tagging policy
│   ├── allowed-locations.json        # Geo-restrict deployments
│   └── deny-public-ip.json           # Block uncontrolled public IPs
├── docs/
│   ├── DEPLOYMENT-GUIDE.md           # 41-step IaC deployment guide (Bicep + PowerShell)
│   ├── PORTAL-DEPLOYMENT-GUIDE.md    # Full portal-only GUI deployment guide (no CLI)
│   ├── architecture/                 # Diagrams
│   └── screenshots/                  # 25 Azure Portal verification screenshots
├── .github/
│   └── workflows/
│       └── validate.yml              # CI: bicep lint + what-if on PR
└── README.md
```

---

## Prerequisites

- Azure subscription with **Contributor** + **User Access Administrator** on the target scope
- Azure CLI ≥ 2.50 with Bicep CLI
- PowerShell 7+
- Git

---

## Quick Start

```powershell
# 1. Authenticate
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# 2. Validate (what-if)
.\scripts\validate.ps1 -Environment prod

# 3. Deploy
.\scripts\deploy.ps1 -Environment prod -Location eastus2

# 4. Verify in portal (see docs/DEPLOYMENT-GUIDE.md for screenshot walkthrough)
```

---

## Estimated Cost

| Resource | Monthly Estimate |
|----------|-----------------|
| Azure Firewall (Basic) | ~$275 |
| Bastion (Basic) | ~$139 |
| 2x VMSS (B2s, 2 instances each) | ~$120 |
| Load Balancers (Standard) | ~$36 |
| Storage (LRS, 100 GB) | ~$2 |
| Log Analytics (5 GB/day) | ~$12 |
| Key Vault | ~$0.03/operation |
| **Total** | **~$585/mo** |

> Swap Firewall Basic → Standard ($950/mo) for production traffic filtering. Use `dev.bicepparam` to deploy smaller SKUs for testing.

---

## Deployment Guides

### Option A: Infrastructure as Code (Bicep + PowerShell)

See **[docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md)** — 41-step deployment using Bicep modules and PowerShell scripts. Recommended for repeatable, version-controlled deployments.

### Option B: Azure Portal GUI Only (No CLI)

See **[docs/PORTAL-DEPLOYMENT-GUIDE.md](docs/PORTAL-DEPLOYMENT-GUIDE.md)** — Complete step-by-step portal walkthrough. Every resource created by clicking through the Azure Portal. Covers all 5 AZ-104 domains across 7 phases with verification checklists.

---

## Live Azure Portal Screenshots

Every resource deployed and verified in a live Azure subscription.

### Resource Groups & Dashboard
| | |
|---|---|
| ![Azure Portal Dashboard](docs/screenshots/01-azure-portal-dashboard.png) | ![Resource Groups](docs/screenshots/05-resource-groups.png) |
| Portal Dashboard | 5 Resource Groups by Function |

### Networking — Hub-Spoke Topology
| | |
|---|---|
| ![Hub VNet Subnets](docs/screenshots/12-hub-vnet-subnets.png) | ![VNet Peering](docs/screenshots/15-vnet-peering.png) |
| Hub VNet — AzureFirewallSubnet, AzureBastionSubnet, GatewaySubnet | 4 VNet Peerings (Hub ↔ Web, Hub ↔ App) |
| ![Bastion Overview](docs/screenshots/14-bastion-overview.png) | ![Route Table UDR](docs/screenshots/18-route-table-udr.png) |
| Azure Bastion — Secure VM Access (no public IPs) | User-Defined Routes — Force traffic through Firewall |
| ![Web Spoke VNet Subnets](docs/screenshots/13-web-vnet-subnets.png) | ![App Spoke VNet Subnets](docs/screenshots/14b-app-vnet-subnets.png) |
| Web Spoke VNet — snet-web (10.1.1.0/24) | App Spoke VNet — snet-app (10.2.1.0/24) |
| ![Azure Firewall](docs/screenshots/13a-firewall-overview.png) | ![Firewall Policy](docs/screenshots/13b-firewall-rules.png) |
| Azure Firewall — Standard SKU, private IP 10.0.1.4 (UDR next-hop) | Firewall Policy — 2 network rules (DNS + NTP allow) |
| ![Service Endpoints](docs/screenshots/32c-service-endpoints.png) | |
| App Spoke subnets — snet-app (workload) + snet-pe (PE-only, 10.2.2.0/28) | |

### Network Security Groups
| | |
|---|---|
| ![NSG Web Rules](docs/screenshots/16-nsg-web-rules.png) | ![NSG App Rules](docs/screenshots/17-nsg-app-rules.png) |
| Web Tier NSG — Allow HTTP/HTTPS inbound | App Tier NSG — Allow traffic from web subnet only |
| ![NSG Management Rules](docs/screenshots/19b-nsg-management-rules.png) | |
| Management NSG — Allow Bastion SSH/RDP, Deny all else | |

### Load Balancers
| | |
|---|---|
| ![LB Web Overview](docs/screenshots/20-lb-web-overview.png) | ![LB Web Rules](docs/screenshots/21-lb-web-rules.png) |
| Public Load Balancer — Web Tier | LB Rules — HTTP/HTTPS with health probes |
| ![LB App Internal](docs/screenshots/22-lb-app-internal.png) | |
| Internal Load Balancer — App Tier | |

### DNS
| | |
|---|---|
| ![DNS Zone Overview](docs/screenshots/23-dns-zone-overview.png) | ![DNS Record Sets](docs/screenshots/24-dns-record-sets.png) |
| Public DNS Zone — A, CNAME, MX, TXT records | Record Sets — Full DNS configuration |
| ![Private DNS Zone](docs/screenshots/24b-private-dns-zone.png) | ![Private Link DNS Zone](docs/screenshots/32b-privatelink-dns-zone.png) |
| Private DNS Zone — Internal name resolution | privatelink.blob.core.windows.net — Auto-managed for storage PE |

### Storage
| | |
|---|---|
| ![Storage Overview](docs/screenshots/25-storage-overview.png) | ![Storage Containers](docs/screenshots/26-storage-containers.png) |
| Storage Account — LRS, blob versioning, soft delete | Blob Containers — deploy, logs, backups |
| ![Storage Lifecycle](docs/screenshots/27-storage-lifecycle.png) | |
| Lifecycle Management — Cool → Archive → Delete | |

### Security
| | |
|---|---|
| ![Key Vault Overview](docs/screenshots/28-keyvault-overview.png) | ![Managed Identity](docs/screenshots/35-managed-identity.png) |
| Key Vault — RBAC mode, purge protection enabled | User-Assigned Managed Identity (automation) |
| ![All Managed Identities](docs/screenshots/36-managed-identities-list.png) | ![Policy Assignments](docs/screenshots/19-policy-assignments.png) |
| 3 Managed Identities — automation, backup, monitoring (least privilege) | Azure Policy — 5 policy assignments enforced subscription-wide |
| ![Custom RBAC Roles](docs/screenshots/08-custom-rbac-roles.png) | |
| Subscription IAM — Roles tab (3 custom roles: VM Operator, Network Viewer, Monitoring Reader Plus) | |

### Compute & Backup
| | |
|---|---|
| ![Recovery Vault](docs/screenshots/30-recovery-vault.png) | |
| Recovery Services Vault — VM + file share backup policies | |

### Monitoring
| | |
|---|---|
| ![Log Analytics](docs/screenshots/38-log-analytics.png) | ![Metric Alert](docs/screenshots/37-metric-alert.png) |
| Log Analytics Workspace — Diagnostics, alerts, VM Insights | Metric Alert — CPU > 85% over 15 min, multi-receiver action group |
| ![VM Insights Solution](docs/screenshots/38b-vm-insights-solution.png) | |
| VM Insights Solution — Per-VM performance + dependency map | |

---

## Teardown

```powershell
.\scripts\teardown.ps1 -Environment prod -Confirm
```

---

## License

MIT
