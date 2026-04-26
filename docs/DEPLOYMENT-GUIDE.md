# Deployment Guide — Enterprise Azure Infrastructure

Complete start-to-finish walkthrough: from Azure free trial signup through full enterprise deployment with portal verification screenshots. Every AZ-104 domain covered at production depth.

---

## Table of Contents

### Phase 0: Setup
1. [Sign Up for Azure Free Trial](#1-sign-up-for-azure-free-trial)
2. [Install Required Tools](#2-install-required-tools)
3. [Clone the Repository](#3-clone-the-repository)

### Phase 1: Identity & Governance (AZ-104: 15-20%)
4. [Configure Entra ID Users (Bulk)](#4-configure-entra-id-users-bulk)
5. [Create Security Groups (Static + Dynamic)](#5-create-security-groups-static--dynamic)
6. [Create Administrative Units](#6-create-administrative-units)
7. [Invite a Guest User](#7-invite-a-guest-user)
8. [Create Custom RBAC Roles](#8-create-custom-rbac-roles)
9. [Assign RBAC to Groups](#9-assign-rbac-to-groups)
10. [Configure Azure Policies](#10-configure-azure-policies)
11. [Apply Resource Locks](#11-apply-resource-locks)

### Phase 2: Networking (AZ-104: 25-30%)
12. [Deploy Hub Virtual Network](#12-deploy-hub-virtual-network)
13. [Deploy Azure Firewall](#13-deploy-azure-firewall)
14. [Deploy Azure Bastion](#14-deploy-azure-bastion)
15. [Deploy Spoke VNets + Peering](#15-deploy-spoke-vnets--peering)
16. [Configure NSGs (Web + App tiers)](#16-configure-nsgs-web--app-tiers)
17. [Configure Route Tables (UDRs)](#17-configure-route-tables-udrs)
18. [Deploy Public + Internal Load Balancers](#18-deploy-public--internal-load-balancers)
19. [Configure Azure DNS (Public + Private)](#19-configure-azure-dns-public--private)
20. [Enable Network Watcher + NSG Flow Logs](#20-enable-network-watcher--nsg-flow-logs)
21. [Network Troubleshooting (IP Flow, Next Hop)](#21-network-troubleshooting-ip-flow-next-hop)

### Phase 3: Storage (AZ-104: 15-20%)
22. [Deploy Storage Account (Blob + Files)](#22-deploy-storage-account-blob--files)
23. [Configure Lifecycle Management](#23-configure-lifecycle-management)
24. [Generate SAS Tokens + Stored Access Policies](#24-generate-sas-tokens--stored-access-policies)
25. [Upload Data with AzCopy](#25-upload-data-with-azcopy)
26. [Rotate Storage Keys](#26-rotate-storage-keys)
27. [Deploy Key Vault (RBAC mode)](#27-deploy-key-vault-rbac-mode)

### Phase 4: Compute (AZ-104: 20-25%)
28. [Deploy VM Scale Sets (Web + App)](#28-deploy-vm-scale-sets-web--app)
29. [Configure Autoscale Rules](#29-configure-autoscale-rules)
30. [Deploy App Service + Deployment Slot](#30-deploy-app-service--deployment-slot)
31. [Deploy Azure Container Instance](#31-deploy-azure-container-instance)
32. [Managed Disks, Snapshots, Image Gallery](#32-managed-disks-snapshots-image-gallery)
33. [Configure VM Backup (Recovery Services)](#33-configure-vm-backup-recovery-services)
34. [Connect via Bastion](#34-connect-via-bastion)

### Phase 5: Monitoring (AZ-104: 10-15%)
35. [Deploy Log Analytics Workspace](#35-deploy-log-analytics-workspace)
36. [Configure Diagnostic Settings (all resources)](#36-configure-diagnostic-settings-all-resources)
37. [Create Metric + Log Alerts](#37-create-metric--log-alerts)
38. [VM Insights + Solutions](#38-vm-insights--solutions)

### Phase 6: Finalize
39. [Take All Screenshots](#39-take-all-screenshots)
40. [Push to GitHub](#40-push-to-github)
41. [Teardown](#41-teardown)

---

## Phase 0: Setup

### 1. Sign Up for Azure Free Trial

**You get**: $200 credit for 30 days + 12 months of free services.

**Step-by-step:**

1. Open your browser and go to:
   ```
   https://azure.microsoft.com/en-us/free/
   ```

2. Click **"Start free"**

3. Sign in with your Microsoft account (or create one)
   - Use a personal email (outlook.com, gmail) — NOT a work/school account
   - If prompted, create a new Microsoft account

4. **Identity verification** — fill in:
   - Country/Region: United States
   - First name, Last name
   - Phone number (for SMS verification)
   - Enter the verification code sent to your phone

5. **Credit card verification** (you will NOT be charged):
   - Enter card details — this is identity verification only
   - You will NOT be charged unless you manually upgrade
   - The $200 credit covers everything in this project

6. **Agreement** — check the boxes and click **Sign up**

7. You'll land on the Azure Portal: `https://portal.azure.com`

> **Screenshot 01**: Azure Portal dashboard after signup showing "$200 credit remaining"
![01-azure-portal-dashboard.png](screenshots/01-azure-portal-dashboard.png)

**Verify your subscription:**
```powershell
az login
az account show --output table
```

> **Screenshot 02**: Terminal showing `az account show` with "Free Trial" subscription

---

### 2. Install Required Tools

**Install Azure CLI** (if not already installed):
```powershell
# Windows (run as Administrator)
winget install Microsoft.AzureCLI

# Verify
az version
```

**Install Bicep CLI:**
```powershell
az bicep install
az bicep version
```

**Install AzCopy:**
```powershell
# Windows
winget install Microsoft.AzCopy

# Verify
azcopy --version
```

**Verify PowerShell 7+:**
```powershell
$PSVersionTable.PSVersion
# If below 7.0:
winget install Microsoft.PowerShell
```

> **Screenshot 03**: Terminal showing all tool versions (az, bicep, azcopy, pwsh)

---

### 3. Clone the Repository

```powershell
cd C:\Projects
git clone https://github.com/YOUR_USERNAME/azure-enterprise-infrastructure.git
cd azure-enterprise-infrastructure
```

---

## Phase 1: Identity & Governance

### 4. Configure Entra ID Users (Bulk)

This creates 10 users across IT, Development, Operations, Security, and Management departments using the included CSV file.

```powershell
# Set your tenant domain (find it in Portal → Entra ID → Overview)
$tenantDomain = "YOUR_TENANT.onmicrosoft.com"

# Run the Entra setup script
.\scripts\entra-setup.ps1 -Environment prod -TenantDomain $tenantDomain
```

**Or create users manually in the Portal:**

1. Go to **Entra ID → Users → New user → Create new user**
2. Fill in: Username, Name, Department, Job title
3. Set "Force password change at next sign-in" = Yes
4. Repeat for each user in `data/bulk-users.csv`

**Verify in Portal:**
- Go to **Entra ID → Users**
- Confirm all 10 users appear with correct departments

> **Screenshot 04**: Entra ID → Users list showing all created users with departments

---

### 5. Create Security Groups (Static + Dynamic)

**Static Security Groups (Portal):**

1. Go to **Entra ID → Groups → New group**
2. Group type: **Security**
3. Create these groups:

| Group Name | Description | Members |
|-----------|-------------|---------|
| `sg-infra-admins-prod` | Infrastructure admins | j.chen, m.rodriguez |
| `sg-network-ops-prod` | Network operations | m.rodriguez |
| `sg-vm-operators-prod` | VM start/stop only | r.jackson |
| `sg-monitoring-readers-prod` | Monitoring team | l.martinez |
| `sg-security-auditors-prod` | Security audit | a.patel, k.williams |
| `sg-backup-operators-prod` | Backup management | t.nguyen |

4. For each group, add the appropriate users as members

**Dynamic Group (requires Entra ID P1 — available in trial):**

1. Go to **Entra ID → Groups → New group**
2. Group type: **Security**
3. Name: `sg-all-it-dynamic-prod`
4. Membership type: **Dynamic User**
5. Click **Add dynamic query**
6. Rule: `(user.department -eq "IT") -and (user.accountEnabled -eq true)`
7. Click **Validate Rules** → verify IT users appear
8. Save

> **Screenshot 05a**: Security groups list showing all 7 groups

> **Screenshot 05b**: Dynamic group rule editor with validation results

---

### 6. Create Administrative Units

Administrative Units scope user management to specific departments.

1. Go to **Entra ID → Administrative units → Add**
2. Name: `AU-IT-Operations-prod`
3. Description: "Scoped management for IT Operations department"
4. Click **Next** → Add users from IT department
5. Click **Next** → Assign "User Administrator" role scoped to this AU to `j.chen`
6. Repeat for `AU-Development-prod` with Development users

> **Screenshot 06**: Administrative Units list with members count

---

### 7. Invite a Guest User

1. Go to **Entra ID → Users → New user → Invite external user**
2. Email: use a personal email you control (for testing)
3. Display name: "External Vendor - Test"
4. Personal message: "You've been invited to collaborate on infrastructure monitoring"
5. Click **Invite**

**Verify:**
- User appears in the users list with "Guest" user type
- Check the invitation email

> **Screenshot 07**: User list showing guest user with "Guest" type badge

---

### 8. Create Custom RBAC Roles

**Deploy via Bicep (automated):**
```powershell
# This deploys as part of the main deployment in Phase 2-4
# For now, verify the role definitions exist after deployment
```

**Or create manually in Portal:**

1. Go to **Subscription → Access Control (IAM) → Roles → Add → Add custom role**
2. Name: `VM Operator (prod)`
3. Permissions tab → Add permissions:
   - `Microsoft.Compute/virtualMachines/read`
   - `Microsoft.Compute/virtualMachines/start/action`
   - `Microsoft.Compute/virtualMachines/restart/action`
   - `Microsoft.Compute/virtualMachines/deallocate/action`
   - `Microsoft.Compute/virtualMachines/powerOff/action`
   - *(same for virtualMachineScaleSets)*
4. Assignable scopes: Select the compute resource group
5. Save

Repeat for:
- **Network Viewer (prod)** — read-only on all `Microsoft.Network/*`
- **Monitoring Reader Plus (prod)** — read metrics + manage alerts, deny action group changes

> **Screenshot 08**: Custom roles list showing all 3 roles with assignable scopes

---

### 9. Assign RBAC to Groups

1. Go to **Subscription → Access Control (IAM) → Add → Add role assignment**
2. Assign:

| Group | Role | Scope |
|-------|------|-------|
| sg-infra-admins-prod | Contributor | Subscription |
| sg-vm-operators-prod | VM Operator (prod) | ent-rg-compute-prod |
| sg-network-ops-prod | Network Viewer (prod) | ent-rg-networking-prod |
| sg-monitoring-readers-prod | Monitoring Reader Plus (prod) | ent-rg-monitoring-prod |
| sg-security-auditors-prod | Reader | ent-rg-security-prod |
| sg-backup-operators-prod | Backup Contributor | ent-rg-compute-prod |

> **Screenshot 09**: IAM → Role assignments showing all group-to-role mappings

---

### 10. Configure Azure Policies

**Deploy all policies at once:**
```powershell
.\scripts\deploy.ps1 -Environment prod -Location eastus2
```

**Or assign manually:**

1. Go to **Policy → Assignments → Assign policy**
2. Assign these built-in policies at subscription scope:

| Policy | Effect | Parameters |
|--------|--------|-----------|
| Require a tag and its value | Deny (prod) / Audit (dev) | Tag: Environment, Value: prod |
| Require a tag on resource groups | Deny | Tag: CostCenter |
| Allowed locations | Deny | eastus2, centralus, westus2 |
| Network interfaces should not have public IPs | Deny | — |
| Secure transfer to storage accounts should be enabled | Audit | — |

**Test policy enforcement:**
```powershell
# This SHOULD fail (wrong location)
az group create -n test-policy-deny -l northeurope --tags Environment=prod CostCenter=test ManagedBy=Bicep
# Expected error: "RequestDisallowedByPolicy"

# Clean up if it somehow succeeded
az group delete -n test-policy-deny --yes --no-wait 2>$null
```

> **Screenshot 10a**: Policy → Assignments showing all 5 policies
![19-policy-assignments.png](screenshots/19-policy-assignments.png)

> **Screenshot 10b**: Terminal showing policy deny error for wrong location

---

### 11. Apply Resource Locks

1. Go to **ent-rg-networking-prod → Locks → Add**
   - Name: `lock-networking-nodelete`
   - Lock type: **Delete**
   - Note: "Production networking — remove lock before deleting"

2. Go to **ent-rg-security-prod → Locks → Add**
   - Name: `lock-security-nodelete`
   - Lock type: **Delete**

3. Go to **ent-rg-monitoring-prod → Locks → Add**
   - Name: `lock-monitoring-readonly`
   - Lock type: **Read-only**

**Test the lock:**
```powershell
# This SHOULD fail
az group delete -n ent-rg-networking-prod --yes
# Expected error: "ScopeLocked"
```

> **Screenshot 11**: Resource group locks showing all 3 locks

---

## Phase 2: Networking

### 12. Deploy Hub Virtual Network

**Deploy everything at once (recommended):**
```powershell
.\scripts\deploy.ps1 -Environment prod -Location eastus2
```

**What gets created:**
- Hub VNet: `ent-vnet-hub-prod` (`10.0.0.0/16`)
- Subnets: AzureFirewallSubnet, AzureBastionSubnet, GatewaySubnet, snet-management

> **Verify**: All 5 resource groups created with proper tags
![05-resource-groups.png](screenshots/05-resource-groups.png)

**Verify in Portal:**
1. Go to **ent-rg-networking-prod → ent-vnet-hub-prod**
2. Click **Subnets** — verify all 4 subnets with correct CIDR ranges
3. Click **Diagram** — see visual layout

> **Screenshot 12**: Hub VNet → Subnets blade showing all 4 subnets with addresses
![12-hub-vnet-subnets.png](screenshots/12-hub-vnet-subnets.png)

---

### 13. Deploy Azure Firewall

**Verify in Portal:**
1. Go to **ent-rg-networking-prod → ent-fw-prod**
2. Check:
   - Provisioning state: Succeeded
   - Public IP assigned
   - Firewall policy linked
3. Go to firewall policy → **Rules** → verify DNS + NTP rules

> **Screenshot 13a**: Azure Firewall overview (provisioning state, IPs)

> **Screenshot 13b**: Firewall policy rules showing DNS and NTP allow rules

---

### 14. Deploy Azure Bastion

**Verify in Portal:**
1. Go to **ent-rg-networking-prod → ent-bastion-prod**
2. Check: SKU = Basic, public IP assigned, connected to AzureBastionSubnet

> **Screenshot 14**: Bastion overview showing SKU and connected VNet
![14-bastion-overview.png](screenshots/14-bastion-overview.png)

---

### 15. Deploy Spoke VNets + Peering

**Verify in Portal:**
1. Go to **ent-vnet-hub-prod → Peerings**
2. Verify all 4 peerings show **"Connected"** status:
   - peer-hub-to-web / peer-web-to-hub
   - peer-hub-to-app / peer-app-to-hub

```powershell
az network vnet peering list -g ent-rg-networking-prod --vnet-name ent-vnet-hub-prod --query "[].{Name:name, State:peeringState}" --output table
```

> **Screenshot 15**: VNet peering list — all 4 connections showing "Connected"
![15-vnet-peering.png](screenshots/15-vnet-peering.png)

![13-web-vnet-subnets.png](screenshots/13-web-vnet-subnets.png)

![14b-app-vnet-subnets.png](screenshots/14b-app-vnet-subnets.png)

---

### 16. Configure NSGs (Web + App tiers)

**Verify in Portal:**
1. Go to **ent-nsg-web-prod → Inbound security rules**
2. Verify rules in priority order:
   - 100: Allow-HTTP (80) from Internet
   - 110: Allow-HTTPS (443) from Internet
   - 120: Allow-LB-Probes from AzureLoadBalancer
   - 200: Allow-Bastion-SSH-RDP from 10.0.2.0/26
   - 4096: Deny-All

3. Go to **ent-nsg-app-prod → Inbound security rules**
4. Verify:
   - 100: Allow-From-Web-Tier (8080, 8443) from 10.1.1.0/24
   - 4096: Deny-All

> **Screenshot 16a**: Web NSG inbound rules in order
![16-nsg-web-rules.png](screenshots/16-nsg-web-rules.png)

> **Screenshot 16b**: App NSG inbound rules — only web tier allowed
![17-nsg-app-rules.png](screenshots/17-nsg-app-rules.png)

---

### 17. Configure Route Tables (UDRs)

**Verify in Portal:**
1. Go to **ent-rt-spoke-to-fw-prod → Routes**
2. Verify:
   - `route-to-firewall`: 0.0.0.0/0 → VirtualAppliance → [Firewall Private IP]
   - `route-spoke-to-spoke`: 10.0.0.0/8 → VirtualAppliance → [Firewall Private IP]
3. Click **Subnets** — verify associated with snet-web and snet-app

> **Screenshot 17**: Route table showing both routes with firewall next hop
![18-route-table-udr.png](screenshots/18-route-table-udr.png)

---

### 18. Deploy Public + Internal Load Balancers

**Verify in Portal:**

**Public LB (ent-lb-web-prod):**
1. Frontend IP: Public IP address assigned
2. Backend pool: web-backend-pool
3. Health probes: HTTP on port 80, path /health
4. Load balancing rules: HTTP (80) + HTTPS (443)
5. Outbound rules: configured

**Internal LB (ent-lb-app-prod):**
1. Frontend IP: Private IP from app subnet
2. Backend pool: app-backend-pool
3. Health probes: TCP on port 8080
4. Load balancing rules: port 8080

> **Screenshot 18a**: Public LB overview — frontend IP, backend pool, rules
![20-lb-web-overview.png](screenshots/20-lb-web-overview.png)

![21-lb-web-rules.png](screenshots/21-lb-web-rules.png)

> **Screenshot 18b**: Internal LB overview — private frontend IP
![22-lb-app-internal.png](screenshots/22-lb-app-internal.png)

---

### 19. Configure Azure DNS (Public + Private)

**Verify in Portal:**
1. Go to **DNS zones → ent-prod.example.com**
2. Verify record sets:
   - `www` (A) — alias to LB public IP
   - `api` (A) — static IP
   - `cdn` (CNAME) → azureedge.net
   - `@` (MX) — mail records
   - `@` (TXT) — SPF record

3. Go to **Private DNS zones → ent.internal.prod**
4. Verify `app-lb` A record → internal LB IP

> **Screenshot 19a**: Public DNS zone with all record types visible
![23-dns-zone-overview.png](screenshots/23-dns-zone-overview.png)

![24-dns-record-sets.png](screenshots/24-dns-record-sets.png)

> **Screenshot 19b**: Private DNS zone with internal A record
![24b-private-dns-zone.png](screenshots/24b-private-dns-zone.png)

---

### 20. Enable Network Watcher + NSG Flow Logs

**Verify in Portal:**
1. Go to **Network Watcher → NSG flow logs**
2. Verify flow logs enabled for both web and app NSGs
3. Traffic Analytics: Enabled, interval: 10 minutes
4. Storage + Log Analytics configured

> **Screenshot 20**: Network Watcher → NSG flow logs showing both NSGs enabled

---

### 21. Network Troubleshooting (IP Flow, Next Hop)

**Run the troubleshooting script:**
```powershell
.\scripts\network-troubleshoot.ps1 -Environment prod
```

**Manual verification in Portal:**

1. **IP Flow Verify** (Network Watcher → IP flow verify):
   - Source VM: web VMSS instance
   - Direction: Outbound
   - Protocol: TCP
   - Local: 10.1.1.4:*
   - Remote: 10.2.1.4:8080
   - Expected: **Access allowed**

2. **Next Hop** (Network Watcher → Next hop):
   - Source: 10.1.1.4
   - Destination: 8.8.8.8
   - Expected: **VirtualAppliance** → Firewall IP

3. **Topology** (Network Watcher → Topology):
   - Select ent-rg-networking-prod
   - Screenshot the full topology diagram

> **Screenshot 21a**: IP Flow Verify showing "Access allowed" for web→app

> **Screenshot 21b**: Next Hop showing firewall as next hop for internet traffic

> **Screenshot 21c**: Network topology diagram

---

## Phase 3: Storage

### 22. Deploy Storage Account (Blob + Files)

**Verify in Portal:**
1. Go to **ent-rg-storage-prod → [storage account]**
2. Check properties:
   - Redundancy: GRS
   - Min TLS: 1.2
   - HTTPS only: Enabled
   - Public blob access: Disabled
3. **Containers**: app-data, backups, diagnostic-logs
4. **File shares**: config-share (50 GB)
5. **Networking**: Default = Deny, Azure Services bypass

> **Screenshot 22a**: Storage account overview — redundancy, security settings
![25-storage-overview.png](screenshots/25-storage-overview.png)

> **Screenshot 22b**: Containers list
![26-storage-containers.png](screenshots/26-storage-containers.png)

> **Screenshot 22c**: File share showing quota and access tier

---

### 23. Configure Lifecycle Management

**Verify in Portal:**
1. Go to **Storage account → Lifecycle management**
2. Verify rules:
   - `move-to-cool-after-30d`: Cool @ 30d, Archive @ 90d, Delete @ 365d
   - `delete-old-versions`: Delete versions after 60d

> **Screenshot 23**: Lifecycle management rules detail view
![27-storage-lifecycle.png](screenshots/27-storage-lifecycle.png)

---

### 24. Generate SAS Tokens + Stored Access Policies

```powershell
.\scripts\storage-operations.ps1 -Environment prod -StorageAccountName "<YOUR_STORAGE_ACCOUNT>"
```

**Manual in Portal:**
1. Go to **Storage account → Shared access signature**
2. Configure:
   - Allowed services: Blob, File
   - Allowed resource types: Service, Container, Object
   - Permissions: Read, List
   - Expiry: 4 hours from now
   - HTTPS only: Yes
3. Click **Generate SAS and connection string**

**Stored Access Policy:**
1. Go to **Storage account → Containers → app-data → Access policy**
2. Add policy: Name=read-only-4hr, Permissions=Read+List, Expiry=4hr
3. Save

> **Screenshot 24a**: SAS generation page with settings

> **Screenshot 24b**: Stored access policy on container

---

### 25. Upload Data with AzCopy

```powershell
# Create a test file
echo "Enterprise test data - $(Get-Date)" > C:\temp\test-upload.txt

# Upload using AzCopy with SAS
azcopy copy "C:\temp\test-upload.txt" "https://<STORAGE>.blob.core.windows.net/app-data?<SAS_TOKEN>"

# Sync a directory
azcopy sync "C:\temp\data-folder" "https://<STORAGE>.blob.core.windows.net/app-data" --recursive
```

**Verify in Portal:**
1. Go to **Containers → app-data → Browse**
2. Confirm the uploaded file appears

> **Screenshot 25**: Blob container showing uploaded file with metadata

---

### 26. Rotate Storage Keys

```powershell
# View current keys
az storage account keys list -n <STORAGE_NAME> -g ent-rg-storage-prod --output table

# Rotate key2
az storage account keys renew -n <STORAGE_NAME> -g ent-rg-storage-prod --key key2
```

**In Portal:**
1. Go to **Storage account → Access keys**
2. Click **Rotate** on key2
3. Confirm

> **Screenshot 26**: Access keys blade showing rotation option

---

### 27. Deploy Key Vault (RBAC mode)

**Verify in Portal:**
1. Go to **ent-rg-security-prod → [key vault]**
2. Verify:
   - Permission model: **Azure RBAC** (not access policies)
   - Soft delete: Enabled (90 days)
   - Purge protection: Enabled
3. Go to **Diagnostic settings** → verify logs sent to Log Analytics

**Add a test secret:**
```powershell
$kvName = az keyvault list -g ent-rg-security-prod --query "[0].name" -o tsv
az keyvault secret set --vault-name $kvName --name "db-connection-string" --value "Server=db.internal;Database=appdb;Encrypted=true"
```

> **Screenshot 27a**: Key Vault overview — RBAC, soft delete, purge protection
![28-keyvault-overview.png](screenshots/28-keyvault-overview.png)

> **Verify**: Three user-assigned managed identities deployed in security RG
![36-managed-identities-list.png](screenshots/36-managed-identities-list.png)

![35-managed-identity.png](screenshots/35-managed-identity.png)

---

## Phase 4: Compute

### 28. Deploy VM Scale Sets (Web + App)

**Verify in Portal:**
1. Go to **ent-rg-compute-prod → ent-vmss-web-prod**
2. Check:
   - Instances: running across zones 1, 2, 3
   - Image: Ubuntu 22.04 LTS
   - Size: Standard_B2s (free trial) or Standard_D2s_v5 (prod)
   - Extensions: CustomScript (nginx), HealthExtension

> **Screenshot 28a**: VMSS overview showing instance count and zones

> **Screenshot 28b**: VMSS instances tab — each in a different zone

> **Screenshot 28c**: VMSS extensions list

---

### 29. Configure Autoscale Rules

**Verify in Portal:**
1. Go to **ent-vmss-web-prod → Scaling**
2. Verify:
   - Custom autoscale enabled
   - Scale out: CPU > 75% for 5 min → add 1 instance
   - Scale in: CPU < 25% for 10 min → remove 1 instance
   - Min: 2, Max: 10 (prod) / 4 (dev)

> **Screenshot 29**: Autoscale configuration showing both rules

---

### 30. Deploy App Service + Deployment Slot

**Verify in Portal:**
1. Go to **ent-rg-compute-prod → ent-webapp-prod-*
2. Check:
   - Runtime: Node.js 20 LTS
   - HTTPS Only: Yes
   - FTPS: Disabled
   - Min TLS: 1.2
3. Click **Deployment slots** → verify "staging" slot exists
4. Click **Scale up** → verify App Service Plan tier

**Test slot swap:**
```powershell
az webapp deployment slot swap -g ent-rg-compute-prod -n <WEBAPP_NAME> --slot staging --target-slot production
```

> **Screenshot 30a**: App Service overview — runtime, HTTPS, URL

> **Screenshot 30b**: Deployment slots showing production + staging

---

### 31. Deploy Azure Container Instance

**Verify in Portal:**
1. Go to **ent-rg-compute-prod → ent-aci-monitor-prod**
2. Check:
   - Status: Running
   - Image: curlimages/curl
   - Restart policy: Always
3. Click **Containers → Logs** — verify health check output

> **Screenshot 31**: ACI container group showing running state and logs

---

### 32. Managed Disks, Snapshots, Image Gallery

**Verify in Portal:**
1. **Managed Disk**: ent-disk-data-shared-prod
   - Size: 128 GB
   - Type: Premium SSD (prod) / Standard SSD (dev)
   - Network: Public access disabled

2. **Snapshot**: ent-snap-data-prod-baseline
   - Source: the managed disk
   - Incremental: Yes

3. **Compute Gallery**: ent_gallery_prod
   - Image definition: ubuntu-web-golden
   - OS: Linux, Gen2, TrustedLaunch

> **Screenshot 32a**: Managed disk overview — size, type, encryption

> **Screenshot 32b**: Disk snapshot showing incremental + source disk

> **Screenshot 32c**: Compute Gallery with image definition

---

### 33. Configure VM Backup (Recovery Services)

**Verify in Portal:**
1. Go to **ent-rg-compute-prod → ent-rsv-prod**
2. Click **Backup policies**:
   - `policy-vm-daily`: Daily @ 2AM, retain 30d/12w/12mo
   - `policy-fileshare-daily`: Daily @ 3AM, retain 30d
3. Click **Backup items** → verify VMs are protected
4. Soft delete: Enabled (14 days)

**Enable backup for a VMSS instance:**
```powershell
# In Portal: Recovery Services vault → Backup → Azure Virtual Machine → Select instances
```

> **Screenshot 33a**: Recovery Services Vault → Backup policies
![30-recovery-vault.png](screenshots/30-recovery-vault.png)

> **Screenshot 33b**: Backup items showing protected VMs

---

### 34. Connect via Bastion

1. Go to a **VMSS instance → Connect → Bastion**
2. Enter username: `azureadmin`
3. Enter password (from deployment parameters)
4. Click **Connect** — SSH session opens in browser

**Verify inside the VM:**
```bash
# In the Bastion SSH session:
nginx -v                    # Nginx installed via custom script extension
curl localhost/health       # Should return "healthy"
hostname                    # Shows VMSS instance name
cat /etc/os-release         # Ubuntu 22.04
```

> **Screenshot 34**: Bastion SSH session showing nginx running and health check

---

## Phase 5: Monitoring

### 35. Deploy Log Analytics Workspace

**Verify in Portal:**
1. Go to **ent-rg-monitoring-prod → ent-law-prod**
2. Check:
   - SKU: Per-GB
   - Retention: 90 days (prod) / 30 days (dev)
   - Daily cap: 10 GB

> **Screenshot 35**: Log Analytics workspace overview — retention, daily cap
![38-log-analytics.png](screenshots/38-log-analytics.png)

---

### 36. Configure Diagnostic Settings (all resources)

Every deployed resource sends diagnostics to Log Analytics:

**Verify by checking any resource:**
1. Go to **any resource → Diagnostic settings**
2. Confirm "send-to-law" is configured
3. Verify logs + metrics are being sent

**Run a KQL query to confirm data flow:**
1. Go to **ent-law-prod → Logs**
2. Run:
```kql
AzureActivity
| summarize count() by ResourceGroup, OperationNameValue
| top 10 by count_
```

> **Screenshot 36a**: Diagnostic settings on Azure Firewall showing Log Analytics

> **Screenshot 36b**: KQL query results in Log Analytics

---

### 37. Create Metric + Log Alerts

**Verify in Portal:**
1. Go to **Monitor → Alerts → Alert rules**
2. Verify:
   - `ent-alert-high-cpu-prod` — Severity 2, CPU > 85%
   - `ent-alert-vm-availability-prod` — Severity 1, availability < 100%
   - `ent-alert-nsg-deny-spike-prod` — Severity 3, >100 denies/10min
3. Go to **Monitor → Action groups**
4. Verify: `ent-ag-critical-prod` with email receiver

> **Screenshot 37a**: Alert rules list showing all 3 alerts

> **Screenshot 37b**: Action group showing email receiver

---

### 38. VM Insights + Solutions

**Verify in Portal:**
1. Go to **Monitor → Virtual Machines → Overview**
2. Check VMInsights is collecting data
3. Go to **ent-law-prod → Solutions** → verify VMInsights installed

> **Screenshot 38**: VM Insights overview showing monitored VMs

---

## Phase 6: Finalize

### 39. Take All Screenshots

Use this checklist to make sure you have all screenshots:

| # | Screenshot | Portal Path | File |
|---|-----------|-------------|------|
| 01 | Portal dashboard | Portal home | `01-azure-portal-dashboard.png` |
| 02 | Subscription | `az account show` | `02-subscription-free-trial.png` |
| 03 | Tool versions | Terminal | `03-tool-versions.png` |
| 04 | Entra users | Entra ID → Users | `04-entra-users.png` |
| 05a | Security groups | Entra ID → Groups | `05a-security-groups.png` |
| 05b | Dynamic group rule | Group → Dynamic membership | `05b-dynamic-group-rule.png` |
| 06 | Administrative units | Entra ID → Admin units | `06-administrative-units.png` |
| 07 | Guest user | Entra ID → Users (Guest) | `07-guest-user.png` |
| 08 | Custom RBAC roles | Subscription → IAM → Roles | `08-custom-rbac-roles.png` |
| 09 | RBAC assignments | Subscription → IAM → Assignments | `09-rbac-assignments.png` |
| 10a | Policy assignments | Policy → Assignments | `10a-policy-assignments.png` |
| 10b | Policy deny test | Terminal | `10b-policy-deny-test.png` |
| 11 | Resource locks | RG → Locks | `11-resource-locks.png` |
| 12 | Hub VNet subnets | VNet → Subnets | `12-hub-vnet-subnets.png` |
| 13a | Firewall overview | Firewall resource | `13a-firewall-overview.png` |
| 13b | Firewall rules | Firewall policy → Rules | `13b-firewall-rules.png` |
| 14 | Bastion overview | Bastion resource | `14-bastion-overview.png` |
| 15 | VNet peering | VNet → Peerings | `15-vnet-peering.png` |
| 16a | Web NSG rules | NSG → Inbound rules | `16a-nsg-web-rules.png` |
| 16b | App NSG rules | NSG → Inbound rules | `16b-nsg-app-rules.png` |
| 17 | Route table UDR | Route table → Routes | `17-route-table-udr.png` |
| 18a | Public LB | LB resource | `18a-public-lb.png` |
| 18b | Internal LB | LB resource | `18b-internal-lb.png` |
| 19a | Public DNS records | DNS zone | `19a-public-dns-records.png` |
| 19b | Private DNS | Private DNS zone | `19b-private-dns.png` |
| 20 | NSG flow logs | Network Watcher → Flow logs | `20-nsg-flow-logs.png` |
| 21a | IP flow verify | Network Watcher | `21a-ip-flow-verify.png` |
| 21b | Next hop | Network Watcher | `21b-next-hop.png` |
| 21c | Network topology | Network Watcher → Topology | `21c-network-topology.png` |
| 22a | Storage overview | Storage account | `22a-storage-overview.png` |
| 22b | Containers | Storage → Containers | `22b-storage-containers.png` |
| 22c | File share | Storage → File shares | `22c-file-share.png` |
| 23 | Lifecycle rules | Storage → Lifecycle mgmt | `23-lifecycle-rules.png` |
| 24a | SAS token | Storage → SAS | `24a-sas-token.png` |
| 24b | Stored access policy | Container → Access policy | `24b-stored-access-policy.png` |
| 25 | AzCopy upload | Container → Browse | `25-azcopy-upload.png` |
| 26 | Key rotation | Storage → Access keys | `26-key-rotation.png` |
| 27a | Key Vault overview | Key Vault | `27a-keyvault-overview.png` |
| 27b | Key Vault secret | Key Vault → Secrets | `27b-keyvault-secret.png` |
| 28a | VMSS overview | VMSS resource | `28a-vmss-web-overview.png` |
| 28b | VMSS zones | VMSS → Instances | `28b-vmss-instances-zones.png` |
| 28c | VMSS extensions | VMSS → Extensions | `28c-vmss-extensions.png` |
| 29 | Autoscale rules | VMSS → Scaling | `29-autoscale-rules.png` |
| 30a | App Service | App Service | `30a-app-service.png` |
| 30b | Deployment slots | App Service → Slots | `30b-deployment-slots.png` |
| 31 | Container instance | ACI resource | `31-container-instance.png` |
| 32a | Managed disk | Disk resource | `32a-managed-disk.png` |
| 32b | Disk snapshot | Snapshot resource | `32b-disk-snapshot.png` |
| 32c | Compute gallery | Gallery resource | `32c-compute-gallery.png` |
| 33a | Backup policies | RSV → Policies | `33a-backup-policies.png` |
| 33b | Backup items | RSV → Items | `33b-backup-items.png` |
| 34 | Bastion session | Bastion SSH | `34-bastion-ssh-session.png` |
| 35 | Log Analytics | LAW resource | `35-log-analytics.png` |
| 36a | Diagnostic settings | Any resource → Diag | `36a-diagnostic-settings.png` |
| 36b | KQL query results | LAW → Logs | `36b-kql-query-results.png` |
| 37a | Alert rules | Monitor → Alerts | `37a-alert-rules.png` |
| 37b | Action group | Monitor → Action groups | `37b-action-group.png` |
| 38 | VM Insights | Monitor → VMs | `38-vm-insights.png` |

**Total: 46 screenshots** covering every AZ-104 domain.

---

### 40. Push to GitHub

```powershell
cd C:\Projects\azure-enterprise-infrastructure
git init
git add -A
git commit -m "Enterprise Azure infrastructure — full AZ-104 domain coverage with Bicep IaC and step-by-step deployment guide"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/azure-enterprise-infrastructure.git
git push -u origin main
```

After taking all screenshots:
```powershell
git add docs/screenshots/
git commit -m "Add portal verification screenshots for all 41 deployment steps"
git push
```

---

## Phase 7: Advanced Coverage (added to close practice-exam gaps)

### 42. Application Security Groups + ASG-based NSG Rules

```powershell
# Already deployed by bicep/modules/asgs.bicep on the next 'deploy.ps1' run.
# Verify:
az network asg list --resource-group ent-rg-networking-prod --output table
# Inspect a rule that now uses ASG references instead of subnet CIDRs:
az network nsg rule show -g ent-rg-networking-prod --nsg-name ent-nsg-app-prod --name Allow-From-Web-Tier --query "{src:sourceApplicationSecurityGroups, dst:destinationApplicationSecurityGroups}" -o json
```

> **Screenshot 42**: ASG list + NSG rule showing ASG references in source/destination

---

### 43. Service Endpoints + Private Endpoints

```powershell
# Service endpoints (already on snet-app):
az network vnet subnet show -g ent-rg-networking-prod --vnet-name ent-vnet-app-prod -n snet-app --query serviceEndpoints

# Private endpoints (deployed by bicep/modules/private-endpoints.bicep):
az network private-endpoint list -g ent-rg-networking-prod --output table
az network private-dns zone list -g ent-rg-networking-prod --output table

# Lock down storage and Key Vault to private only:
az storage account update -g ent-rg-storage-prod -n entstprodjtijk6lp --public-network-access Disabled
az keyvault update -g ent-rg-security-prod -n ent-kv-prod-x7m2k1 --public-network-access Disabled
```

> **Screenshot 43a**: Storage Account → Networking → publicNetworkAccess = Disabled, PE shown
> **Screenshot 43b**: Key Vault → Networking → publicNetworkAccess = Disabled, PE shown

---

### 44. VPN Gateway (Basic SKU, P2S)

```powershell
# Provisioning takes 30-45 minutes. Deploy via:
az deployment sub create --location eastus2 --template-file bicep/main.bicep --parameters bicep/parameters/prod.bicepparam

# After provisioning, generate a self-signed root cert and upload:
$cert = New-SelfSignedCertificate -Type Custom -KeySpec Signature -Subject "CN=entRootCert" -KeyExportPolicy Exportable -HashAlgorithm sha256 -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -KeyUsageProperty Sign -KeyUsage CertSign
$certPub = [Convert]::ToBase64String($cert.RawData)
az network vnet-gateway root-cert create -g ent-rg-networking-prod --gateway-name ent-vpngw-prod -n entRootCert --public-cert-data $certPub
```

> **Screenshot 44**: VPN Gateway overview — Status: Succeeded, IP allocated

---

### 45. Azure Disk Encryption with Key Vault KEK

```powershell
.\scripts\enable-disk-encryption.ps1 `
    -ResourceGroup ent-rg-compute-prod `
    -VmName <vm-name> `
    -KeyVaultName ent-kv-prod-x7m2k1
```

> **Screenshot 45**: VM → Disks blade showing encryption: Customer-Managed (Azure)

---

### 46. Conditional Access + Custom Security Attributes + Management Groups + Defender (Free)

```powershell
# Conditional Access — requires Microsoft.Graph PowerShell:
.\scripts\configure-conditional-access.ps1

# Custom security attributes:
.\scripts\define-custom-security-attributes.ps1

# Management groups:
.\scripts\setup-management-group.ps1 -SubscriptionId (az account show --query id -o tsv)

# Defender for Cloud Free pricing was set by bicep/modules/governance.bicep on the last 'deploy.ps1' run.
az security pricing list --query "[].{plan:name, tier:pricingTier}" -o table
```

> **Screenshot 46a**: Conditional Access policy in report-only mode
> **Screenshot 46b**: Custom security attribute set 'WorkforcePartition' with 3 values
> **Screenshot 46c**: Management group hierarchy (root → prod → subscription)
> **Screenshot 46d**: Defender for Cloud secure score (after 24h)

---

### 47. Multi-tier Backup Retention + Operations Workbook + Multi-Receiver Action Group

All deployed by the updated Bicep modules. Verify:

```powershell
# Backup policy — confirm 4 retention tiers:
az backup policy show --vault-name ent-rsv-prod --resource-group ent-rg-compute-prod --name policy-vm-daily --query "properties.retentionPolicy" -o json

# Workbook:
az resource list -g ent-rg-monitoring-prod --resource-type Microsoft.Insights/workbooks -o table

# Action group:
az monitor action-group show -g ent-rg-monitoring-prod -n ent-ag-critical-prod --query "{emails:emailReceivers[].name, sms:smsReceivers[].name, webhooks:webhookReceivers[].name}" -o json
```

> **Screenshot 47a**: Backup policy with daily/weekly/monthly/yearly tiers
> **Screenshot 47b**: Operations workbook with 4 KQL panels rendering
> **Screenshot 47c**: Action group with 4 receiver types

---

### 41. Teardown

**IMPORTANT:** Delete resources when done to avoid charges.

```powershell
# Teardown (removes resource locks first, then deletes all RGs)
.\scripts\teardown.ps1 -Environment prod -Confirm

# Verify everything is gone
az group list --query "[?starts_with(name,'ent-rg')]" --output table
```

**Free trial note:** Your $200 credit covers ~10 days of this deployment. Tear down within 3-5 days to stay well within budget.

---

## AZ-104 Domain Coverage Summary

| Domain | Weight | Steps Covered | Key Resources |
|--------|--------|--------------|---------------|
| **Identity & Governance** | 15-20% | Steps 4-11 | Bulk users, dynamic groups, admin units, guest invite, custom RBAC, policies, locks |
| **Networking** | 25-30% | Steps 12-21 | Hub-spoke, firewall, bastion, peering, NSGs, UDRs, LBs, DNS, Network Watcher, flow logs, IP flow verify, next hop |
| **Storage** | 15-20% | Steps 22-27 | Blob, files, lifecycle, SAS, stored policies, AzCopy, key rotation, Key Vault |
| **Compute** | 20-25% | Steps 28-34 | VMSS, autoscale, App Service, slots, ACI, ACR, managed disks, snapshots, gallery, backup, bastion SSH |
| **Monitoring** | 10-15% | Steps 35-38 | Log Analytics, diagnostics on all resources, metric/log alerts, action groups, VM Insights, KQL |
