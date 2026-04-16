# Azure Portal GUI Deployment Guide — Enterprise Infrastructure

Complete step-by-step walkthrough to deploy the entire enterprise Azure infrastructure using **only the Azure Portal GUI**. No CLI, no Bicep, no PowerShell — every resource created by clicking through the portal.

Covers all five AZ-104 exam domains at production depth.

---

## Table of Contents

- [Phase 0: Prerequisites](#phase-0-prerequisites)
- [Phase 1: Resource Groups](#phase-1-resource-groups)
- [Phase 2: Identity & Governance](#phase-2-identity--governance)
- [Phase 3: Networking](#phase-3-networking)
- [Phase 4: Storage](#phase-4-storage)
- [Phase 5: Security](#phase-5-security)
- [Phase 6: Compute](#phase-6-compute)
- [Phase 7: Monitoring](#phase-7-monitoring)

---

## Phase 0: Prerequisites

### Step 0.1 — Sign Up for Azure Free Trial

1. Go to `https://azure.microsoft.com/en-us/free/`
2. Click **Start free**
3. Sign in with a Microsoft account (or create one with a personal email)
4. Complete identity verification (phone + credit card — you will NOT be charged)
5. Click **Sign up** — you land on `https://portal.azure.com` with $200 credit

---

## Phase 1: Resource Groups

> **AZ-104 Domain**: Identity & Governance (15-20%)
> Resource groups are logical containers that hold related Azure resources. Every resource must belong to exactly one resource group. They provide lifecycle management, access control boundaries, and cost tracking.

### Step 1.1 — Create Resource Groups

Create 5 resource groups to organize resources by function. This follows the principle of least privilege — each group gets its own RBAC scope.

1. Portal Home → **Resource groups** → **Create**
2. Fill in:
   - **Subscription**: Azure subscription 1
   - **Resource group**: `ent-rg-networking-prod`
   - **Region**: East US 2
3. Click **Tags** tab:
   - `Environment` = `prod`
   - `ManagedBy` = `Bicep`
   - `Project` = `enterprise-infra`
   - `CostCenter` = `IT-OPS-001`
4. Click **Review + create** → **Create**

Repeat for these 4 additional resource groups (same region, same tags):

| Resource Group | Purpose |
|---|---|
| `ent-rg-compute-prod` | VMs, VMSS, Recovery Services |
| `ent-rg-storage-prod` | Storage accounts |
| `ent-rg-security-prod` | Key Vault, Managed Identities |
| `ent-rg-monitoring-prod` | Log Analytics, Alerts |

**Verify**: Go to **Resource groups** — all 5 should appear with "East US 2" location.

> Screenshot: `docs/screenshots/05-resource-groups.png`

---

## Phase 2: Identity & Governance

> **AZ-104 Domain**: Identity & Governance (15-20%)
> Microsoft Entra ID (formerly Azure AD) manages identity. RBAC controls who can do what. Policies enforce organizational standards. Locks prevent accidental deletion.

### Step 2.1 — Create Entra ID Users

1. Portal → **Microsoft Entra ID** → **Users** → **New user** → **Create new user**
2. For each user below, fill in:
   - **User principal name**: (name)@(yourtenant).onmicrosoft.com
   - **Display name**: (full name)
   - **Job title**: (title)
   - **Department**: (department)
   - **Usage location**: United States
   - Check **Auto-generate password** and note the temporary password
3. Click **Create**

| Username | Display Name | Department | Job Title |
|---|---|---|---|
| `j.chen` | James Chen | IT | Sr. Infrastructure Admin |
| `m.rodriguez` | Maria Rodriguez | IT | Network Operations Lead |
| `a.patel` | Anya Patel | Security | Security Analyst |
| `s.kim` | Sarah Kim | Development | Lead Developer |
| `r.jackson` | Robert Jackson | Operations | VM Operations Specialist |
| `l.martinez` | Luis Martinez | Operations | Monitoring Engineer |
| `k.williams` | Karen Williams | Security | Compliance Officer |
| `t.nguyen` | Thomas Nguyen | Operations | Backup Administrator |
| `e.davis` | Emily Davis | Development | DevOps Engineer |
| `d.wilson` | David Wilson | Management | IT Director |

### Step 2.2 — Create Security Groups

1. **Microsoft Entra ID** → **Groups** → **New group**
2. Group type: **Security**
3. Create each group and add members:

| Group Name | Members |
|---|---|
| `sg-infra-admins-prod` | j.chen, m.rodriguez |
| `sg-network-ops-prod` | m.rodriguez |
| `sg-vm-operators-prod` | r.jackson |
| `sg-monitoring-readers-prod` | l.martinez |
| `sg-security-auditors-prod` | a.patel, k.williams |
| `sg-backup-operators-prod` | t.nguyen |

4. **Dynamic group** (requires Entra ID P1 — available in free trial):
   - **New group** → Group type: **Security** → Membership type: **Dynamic User**
   - Name: `sg-all-it-dynamic-prod`
   - Click **Add dynamic query** → Rule: `(user.department -eq "IT")`
   - **Validate Rules** → verify IT users appear → **Save**

### Step 2.3 — Create Custom RBAC Roles

1. Portal → **Subscriptions** → select your subscription → **Access control (IAM)**
2. **Roles** tab → **Add** → **Add custom role**
3. Click **Start from JSON** or **Start from scratch**

**Role 1: VM Operator (prod)**
- Name: `VM Operator (prod)`
- Description: Start, stop, restart VMs and VMSS — no create/delete
- Permissions → **Add permissions**:
  - `Microsoft.Compute/virtualMachines/read`
  - `Microsoft.Compute/virtualMachines/start/action`
  - `Microsoft.Compute/virtualMachines/restart/action`
  - `Microsoft.Compute/virtualMachines/deallocate/action`
  - `Microsoft.Compute/virtualMachines/powerOff/action`
  - `Microsoft.Compute/virtualMachineScaleSets/read`
  - `Microsoft.Compute/virtualMachineScaleSets/start/action`
  - `Microsoft.Compute/virtualMachineScaleSets/restart/action`
  - `Microsoft.Compute/virtualMachineScaleSets/deallocate/action`
- Assignable scopes: `/subscriptions/{your-sub-id}/resourceGroups/ent-rg-compute-prod`
- **Review + create**

**Role 2: Network Viewer (prod)**
- Name: `Network Viewer (prod)`
- Description: Read-only access to all networking resources
- Permissions: `Microsoft.Network/*/read`
- Assignable scopes: `/subscriptions/{your-sub-id}/resourceGroups/ent-rg-networking-prod`

**Role 3: Monitoring Reader Plus (prod)**
- Name: `Monitoring Reader Plus (prod)`
- Description: Read metrics, manage alerts, deny action group changes
- Permissions:
  - `Microsoft.Insights/metrics/read`
  - `Microsoft.Insights/alertRules/*`
  - `Microsoft.Insights/metricAlerts/*`
  - `Microsoft.OperationalInsights/workspaces/read`
  - `Microsoft.OperationalInsights/workspaces/query/read`
- Not Actions: `Microsoft.Insights/actionGroups/write`
- Assignable scopes: `/subscriptions/{your-sub-id}/resourceGroups/ent-rg-monitoring-prod`

### Step 2.4 — Assign RBAC Roles to Groups

1. **Subscriptions** → your subscription → **Access control (IAM)** → **Add** → **Add role assignment**
2. For each assignment:
   - Select **Role** → search for the role name
   - Click **Members** tab → **Select members** → search for the group
   - **Review + assign**

| Group | Role | Scope |
|---|---|---|
| sg-infra-admins-prod | Contributor | Subscription |
| sg-vm-operators-prod | VM Operator (prod) | ent-rg-compute-prod |
| sg-network-ops-prod | Network Viewer (prod) | ent-rg-networking-prod |
| sg-monitoring-readers-prod | Monitoring Reader Plus (prod) | ent-rg-monitoring-prod |
| sg-security-auditors-prod | Reader | ent-rg-security-prod |
| sg-backup-operators-prod | Backup Contributor | ent-rg-compute-prod |

### Step 2.5 — Assign Azure Policies

1. Portal → **Policy** → **Assignments** → **Assign policy**
2. For each policy:
   - **Scope**: Select your subscription
   - **Policy definition**: Search for the built-in policy name
   - Fill in parameters
   - **Review + create**

| Policy Definition (built-in) | Effect | Parameters |
|---|---|---|
| Require a tag and its value on resources | Deny | Tag: `Environment`, Value: `prod` |
| Require a tag on resource groups | Deny | Tag: `CostCenter` |
| Allowed locations | Deny | `eastus2`, `centralus`, `westus2` |
| Network interfaces should not have public IPs | Deny | — |
| Secure transfer to storage accounts should be enabled | Audit | — |

**Test**: Try creating a resource group in North Europe — it should fail with "RequestDisallowedByPolicy".

### Step 2.6 — Apply Resource Locks

1. Go to **ent-rg-networking-prod** → **Locks** (left menu) → **Add**
   - Name: `lock-networking-nodelete`
   - Lock type: **Delete**
   - Note: "Production networking — remove lock before deleting"
2. Go to **ent-rg-security-prod** → **Locks** → **Add**
   - Name: `lock-security-nodelete`
   - Lock type: **Delete**
3. Go to **ent-rg-monitoring-prod** → **Locks** → **Add**
   - Name: `lock-monitoring-readonly`
   - Lock type: **Read-only**

**Test**: Try deleting `ent-rg-networking-prod` — it should fail with "ScopeLocked".

---

## Phase 3: Networking

> **AZ-104 Domain**: Networking (25-30%)
> Hub-spoke topology routes all traffic through a central firewall. NSGs filter traffic at the subnet level. UDRs override Azure's default routing. Load balancers distribute traffic across backend pools. DNS provides name resolution.

### Step 3.1 — Create Hub Virtual Network

1. Portal → **Virtual networks** → **Create**
2. **Basics** tab:
   - Resource group: `ent-rg-networking-prod`
   - Name: `ent-vnet-hub-prod`
   - Region: East US 2
3. **IP Addresses** tab:
   - Address space: `10.0.0.0/16`
   - Delete the default subnet
   - **Add subnet**:

| Subnet Name | Address Range | Purpose |
|---|---|---|
| `AzureFirewallSubnet` | `10.0.1.0/26` | Required name for Azure Firewall |
| `AzureBastionSubnet` | `10.0.2.0/26` | Required name for Azure Bastion |
| `GatewaySubnet` | `10.0.3.0/27` | Required name for VPN/ExpressRoute Gateway |
| `snet-management` | `10.0.4.0/24` | Management jump boxes |

4. **Tags**: `Environment`=`prod`, `ManagedBy`=`Bicep`, `Project`=`enterprise-infra`, `CostCenter`=`IT-OPS-001`
5. **Review + create** → **Create**

> Screenshot: `docs/screenshots/12-hub-vnet-subnets.png`

### Step 3.2 — Create Web Spoke Virtual Network

1. **Virtual networks** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-vnet-web-prod`
4. Region: East US 2
5. Address space: `10.1.0.0/16`
6. Add subnet:
   - Name: `snet-web`
   - Range: `10.1.1.0/24`
7. Tags (same as hub)
8. **Create**

### Step 3.3 — Create App Spoke Virtual Network

1. **Virtual networks** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-vnet-app-prod`
4. Region: East US 2
5. Address space: `10.2.0.0/16`
6. Add subnet:
   - Name: `snet-app`
   - Range: `10.2.1.0/24`
7. Tags (same as hub)
8. **Create**

### Step 3.4 — Create VNet Peerings (Hub-Spoke)

Hub-to-Web peering:
1. Go to **ent-vnet-hub-prod** → **Peerings** → **Add**
2. This virtual network:
   - Peering link name: `peer-hub-to-web`
   - Allow traffic to remote VNet: **Enabled**
   - Allow forwarded traffic: **Enabled**
   - Allow gateway transit: **Enabled** (hub side only)
3. Remote virtual network:
   - Peering link name: `peer-web-to-hub`
   - Virtual network: `ent-vnet-web-prod`
   - Allow traffic to remote VNet: **Enabled**
   - Allow forwarded traffic: **Enabled**
   - Use remote gateway: **Disabled**
4. Click **Add**

Hub-to-App peering:
1. Go to **ent-vnet-hub-prod** → **Peerings** → **Add**
2. Repeat the same pattern:
   - This side: `peer-hub-to-app` (allow gateway transit)
   - Remote side: `peer-app-to-hub` on `ent-vnet-app-prod`
3. Click **Add**

**Verify**: Both peerings should show **Peering status: Connected** and **Fully Synchronized**.

> Screenshot: `docs/screenshots/15-vnet-peering.png`

### Step 3.5 — Create Azure Firewall

1. Portal → **Firewalls** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-networking-prod`
   - Name: `ent-fw-prod`
   - Region: East US 2
   - Firewall SKU: **Standard**
   - Firewall management: **Use a Firewall Policy to manage this firewall**
   - Firewall policy: **Add new** → name: `ent-fw-policy-prod`
   - Virtual network: `ent-vnet-hub-prod` (choose existing)
   - Public IP: **Add new** → name: `ent-fw-pip-prod`
3. **Tags** (same as before)
4. **Review + create** → **Create** (takes ~10 minutes)

After creation — add firewall rules:
1. Go to **ent-fw-policy-prod** → **Rule collections** → **Add a rule collection**
2. Name: `net-allow-dns-ntp`
3. Rule collection type: **Network**
4. Priority: `100`
5. Action: **Allow**
6. Add rules:

| Rule Name | Source | Destination | Port | Protocol |
|---|---|---|---|---|
| allow-dns | `10.0.0.0/8` | `*` | `53` | UDP |
| allow-ntp | `10.0.0.0/8` | `*` | `123` | UDP |
| allow-http-out | `10.0.0.0/8` | `*` | `80,443` | TCP |

7. Click **Add**

**Note the Firewall private IP** (found on the Firewall overview page) — you need this for route tables.

### Step 3.6 — Create Azure Bastion

1. Portal → **Bastions** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-bastion-prod`
4. Region: East US 2
5. Virtual network: `ent-vnet-hub-prod`
6. Subnet: `AzureBastionSubnet` (auto-selected)
7. Public IP: **Create new** → name: `ent-bastion-pip-prod`
8. **Tags** → **Review + create** → **Create** (takes ~5 minutes)

> Screenshot: `docs/screenshots/14-bastion-overview.png`

### Step 3.7 — Create Network Security Groups (NSGs)

**Web Tier NSG:**
1. Portal → **Network security groups** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-nsg-web-prod`
4. Region: East US 2
5. **Create**

After creation, add inbound rules:
1. Go to **ent-nsg-web-prod** → **Inbound security rules** → **Add**
2. Add each rule:

| Priority | Name | Source | Port | Protocol | Action |
|---|---|---|---|---|---|
| 100 | Allow-HTTP | Any | 80 | TCP | Allow |
| 110 | Allow-HTTPS | Any | 443 | TCP | Allow |
| 120 | Allow-LB-Probes | Service Tag: AzureLoadBalancer | * | Any | Allow |
| 200 | Allow-Bastion-SSH-RDP | 10.0.2.0/26 | 22,3389 | TCP | Allow |
| 4096 | Deny-All-Inbound | Any | * | Any | Deny |

Associate NSG to subnet:
1. Go to **ent-nsg-web-prod** → **Subnets** → **Associate**
2. Virtual network: `ent-vnet-web-prod`
3. Subnet: `snet-web`

> Screenshot: `docs/screenshots/16-nsg-web-rules.png`

**App Tier NSG:**
1. **Network security groups** → **Create**
2. Name: `ent-nsg-app-prod`
3. Resource group: `ent-rg-networking-prod`
4. Region: East US 2
5. **Create**

Inbound rules:

| Priority | Name | Source | Port | Protocol | Action |
|---|---|---|---|---|---|
| 100 | Allow-From-Web-Tier | 10.1.1.0/24 | 8080,8443 | TCP | Allow |
| 4096 | Deny-All-Inbound | Any | * | Any | Deny |

Associate to subnet:
1. **ent-nsg-app-prod** → **Subnets** → **Associate**
2. VNet: `ent-vnet-app-prod`, Subnet: `snet-app`

> Screenshot: `docs/screenshots/17-nsg-app-rules.png`

### Step 3.8 — Create Route Table (UDR)

1. Portal → **Route tables** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-rt-spoke-prod`
4. Region: East US 2
5. Propagate gateway routes: **No** (forces all traffic through firewall)
6. **Create**

Add routes:
1. Go to **ent-rt-spoke-prod** → **Routes** → **Add**

| Route Name | Address prefix | Next hop type | Next hop address |
|---|---|---|---|
| `route-to-firewall` | `0.0.0.0/0` | Virtual appliance | (Firewall private IP) |
| `route-spoke-to-spoke` | `10.0.0.0/8` | Virtual appliance | (Firewall private IP) |

Associate to subnets:
1. **ent-rt-spoke-prod** → **Subnets** → **Associate**
2. VNet: `ent-vnet-web-prod`, Subnet: `snet-web` → **OK**
3. Repeat: VNet: `ent-vnet-app-prod`, Subnet: `snet-app` → **OK**

> Screenshot: `docs/screenshots/18-route-table-udr.png`

### Step 3.9 — Create Public Load Balancer (Web Tier)

1. Portal → **Load balancers** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-networking-prod`
   - Name: `ent-lb-web-prod`
   - Region: East US 2
   - SKU: **Standard**
   - Type: **Public**
   - Tier: **Regional**
3. **Frontend IP configuration** → **Add**:
   - Name: `web-frontend`
   - Public IP: **Create new** → name: `ent-lb-web-pip-prod`
4. **Backend pools** → **Add**:
   - Name: `web-backend-pool`
   - Virtual network: `ent-vnet-web-prod`
5. **Inbound rules** → **Add a load balancing rule**:
   - Name: `http-rule`
   - Frontend IP: `web-frontend`
   - Backend pool: `web-backend-pool`
   - Port: 80 → Backend port: 80
   - Health probe: **Create new** → name: `web-health-probe`, Protocol: HTTP, Port: 80, Path: `/health`
   - Session persistence: None
   - Idle timeout: 4 minutes
6. **Add another load balancing rule** for HTTPS:
   - Name: `https-rule`
   - Port: 443 → Backend port: 443
   - Same health probe
7. **Outbound rules** → **Add**:
   - Name: `web-outbound`
   - Frontend IP: `web-frontend`
   - Backend pool: `web-backend-pool`
8. **Tags** → **Review + create** → **Create**

> Screenshot: `docs/screenshots/20-lb-web-overview.png`
> Screenshot: `docs/screenshots/21-lb-web-rules.png`

### Step 3.10 — Create Internal Load Balancer (App Tier)

1. **Load balancers** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-networking-prod`
   - Name: `ent-lb-app-prod`
   - Region: East US 2
   - SKU: **Standard**
   - Type: **Internal**
3. **Frontend IP** → **Add**:
   - Name: `app-frontend`
   - Virtual network: `ent-vnet-app-prod`
   - Subnet: `snet-app`
   - Assignment: **Dynamic** (or Static if you need a fixed IP)
4. **Backend pools** → **Add**:
   - Name: `app-backend-pool`
   - Virtual network: `ent-vnet-app-prod`
5. **Inbound rules** → **Add a load balancing rule**:
   - Name: `app-rule`
   - Port: 8080 → Backend port: 8080
   - Health probe: **Create new** → name: `app-health-probe`, Protocol: TCP, Port: 8080
   - Enable Floating IP: No
6. **Tags** → **Review + create** → **Create**

> Screenshot: `docs/screenshots/22-lb-app-internal.png`

### Step 3.11 — Create Public DNS Zone

1. Portal → **DNS zones** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent-prod.example.com`
4. **Tags** → **Create**

Add record sets:
1. Go to **ent-prod.example.com** → **Record set** → **Add**

| Name | Type | TTL | Value |
|---|---|---|---|
| `www` | A | 3600 | (Public LB IP or alias) |
| `api` | A | 3600 | `10.1.1.4` |
| `cdn` | CNAME | 3600 | `azureedge.net` |
| `@` | MX | 3600 | Priority: 10, `mail.example.com` |
| `@` | TXT | 3600 | `v=spf1 include:spf.protection.outlook.com -all` |

> Screenshot: `docs/screenshots/23-dns-zone-overview.png`
> Screenshot: `docs/screenshots/24-dns-record-sets.png`

### Step 3.12 — Create Private DNS Zone

1. Portal → **Private DNS zones** → **Create**
2. Resource group: `ent-rg-networking-prod`
3. Name: `ent.internal.prod`
4. **Tags** → **Create**

Link to VNets:
1. Go to **ent.internal.prod** → **Virtual network links** → **Add**
2. Link name: `link-hub`, Virtual network: `ent-vnet-hub-prod`, Enable auto registration: No → **OK**
3. Repeat for `ent-vnet-web-prod` and `ent-vnet-app-prod`

Add A record:
1. **Record set** → **Add**
2. Name: `app-lb`, Type: A, TTL: 3600, IP: (Internal LB frontend IP)

> Screenshot: `docs/screenshots/24b-private-dns-zone.png`

---

## Phase 4: Storage

> **AZ-104 Domain**: Storage (15-20%)
> Storage accounts provide blob, file, table, and queue storage. Lifecycle management automates data tiering. GRS provides geo-redundancy. Soft delete and versioning protect against accidental data loss.

### Step 4.1 — Create Storage Account

1. Portal → **Storage accounts** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-storage-prod`
   - Storage account name: `entstprod` + random suffix (must be globally unique, lowercase, no hyphens)
   - Region: East US 2
   - Performance: **Standard**
   - Redundancy: **Geo-redundant storage (GRS)**
3. **Advanced**:
   - Require secure transfer: **Enabled**
   - Allow blob anonymous access: **Disabled**
   - Enable storage account key access: **Enabled**
   - Minimum TLS version: **1.2**
   - Enable blob soft delete: **Enabled** (7 days)
   - Enable container soft delete: **Enabled** (7 days)
   - Enable versioning: **Enabled**
4. **Networking**:
   - Network access: **Enabled from all networks** (can restrict later)
5. **Data protection**:
   - Enable point-in-time restore: Optional
   - Enable blob change feed: **Enabled**
6. **Tags** (same as all resources)
7. **Review + create** → **Create**

Create blob containers:
1. Go to the storage account → **Containers** → **+ Container**
2. Create:

| Container Name | Access Level |
|---|---|
| `deployments` | Private |
| `backups` | Private |
| `logs` | Private |
| `config` | Private |

> Screenshot: `docs/screenshots/25-storage-overview.png`
> Screenshot: `docs/screenshots/26-storage-containers.png`

### Step 4.2 — Configure Lifecycle Management

1. Go to the storage account → **Lifecycle management** (left menu, under Data management)
2. Click **Add a rule**

**Rule 1: Move to Cool after 30 days**
- Rule name: `move-to-cool`
- Rule scope: Apply to all blobs
- Blob type: Block blobs
- Blob subtype: Base blobs
- Condition: Last modified more than **30** days ago → **Move to cool storage**
- **Add**

**Rule 2: Move to Archive after 90 days**
- Rule name: `move-to-archive`
- Condition: Last modified more than **90** days ago → **Move to archive storage**

**Rule 3: Delete old blobs after 365 days**
- Rule name: `delete-old-blobs`
- Condition: Last modified more than **365** days ago → **Delete the blob**

**Rule 4: Delete old snapshots after 90 days**
- Rule name: `delete-old-snapshots`
- Blob subtype: **Snapshots**
- Condition: Created more than **90** days ago → **Delete the snapshot**

> Screenshot: `docs/screenshots/27-storage-lifecycle.png`

---

## Phase 5: Security

> **AZ-104 Domain**: Identity & Governance + Storage
> Key Vault stores secrets, keys, and certificates with HSM-backed protection. Managed Identities eliminate the need for credential management in code. RBAC authorization replaces legacy access policies.

### Step 5.1 — Create Key Vault

1. Portal → **Key vaults** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-security-prod`
   - Key vault name: `ent-kv-prod-` + random suffix (globally unique)
   - Region: East US 2
   - Pricing tier: **Standard**
3. **Access configuration**:
   - Permission model: **Azure role-based access control (RBAC)** (not access policies)
4. **Networking**:
   - Allow public access: Yes (can restrict later for production)
5. **Recovery**:
   - Soft delete: **Enabled** (default 90 days)
   - Purge protection: **Enabled** (prevents permanent deletion even by admins)
6. **Tags** → **Review + create** → **Create**

> Screenshot: `docs/screenshots/28-keyvault-overview.png`

### Step 5.2 — Create User-Assigned Managed Identities

Create 3 managed identities that services will use instead of storing credentials.

1. Portal → **Managed Identities** → **Create**
2. For each identity:

| Name | Resource Group | Region | Purpose |
|---|---|---|---|
| `id-automation-prod` | `ent-rg-security-prod` | East US 2 | Automation runbooks |
| `id-monitoring-prod` | `ent-rg-security-prod` | East US 2 | Monitoring agents |
| `id-backup-prod` | `ent-rg-security-prod` | East US 2 | Backup operations |

3. Fill in each, add tags, and **Create**

> Screenshot: `docs/screenshots/35-managed-identity.png`

---

## Phase 6: Compute

> **AZ-104 Domain**: Compute (20-25%)
> VMSS provides auto-scaling groups of identical VMs. Recovery Services Vault protects workloads with backup and disaster recovery. Availability Zones ensure high availability across data center failures.

### Step 6.1 — Create Recovery Services Vault

1. Portal → **Recovery Services vaults** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-compute-prod`
   - Vault name: `ent-rsv-prod`
   - Region: East US 2
3. **Redundancy**:
   - Backup Storage Redundancy: **Geo-redundant**
4. **Tags** → **Review + create** → **Create**

After creation — configure backup policies:
1. Go to **ent-rsv-prod** → **Backup policies** → **Add**
2. Policy type: **Azure Virtual Machine**
3. Policy name: `vm-daily-backup`
4. Schedule:
   - Frequency: **Daily**
   - Time: 2:00 AM
   - Timezone: Eastern Standard Time
5. Retention:
   - Daily: **30** days
   - Weekly: **12** weeks (Sunday)
   - Monthly: **12** months (First Sunday)
   - Yearly: **3** years (January, First Sunday)
6. **Create**

> Screenshot: `docs/screenshots/30-recovery-vault.png`

### Step 6.2 — Create Web Tier VM Scale Set

1. Portal → **Virtual machine scale sets** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-compute-prod`
   - Name: `ent-vmss-web-prod`
   - Region: East US 2
   - Availability zone: **Zones 1, 2, 3** (select all three)
   - Orchestration mode: **Uniform**
   - Image: **Ubuntu Server 22.04 LTS**
   - Size: **Standard_B2s** (2 vCPU, 4 GB — fits free trial)
   - Authentication: **SSH public key**
   - Username: `azureadmin`
3. **Networking**:
   - Virtual network: `ent-vnet-web-prod`
   - Subnet: `snet-web`
   - Network security group: `ent-nsg-web-prod`
   - Load balancer: `ent-lb-web-prod`
   - Backend pool: `web-backend-pool`
4. **Scaling**:
   - Initial instance count: **2**
   - Scaling policy: **Custom**
   - Minimum: 2, Maximum: 6, Default: 2
   - Scale out: CPU > 70% for 5 minutes → add 1 instance
   - Scale in: CPU < 30% for 10 minutes → remove 1 instance
5. **Management**:
   - Upgrade policy: **Rolling** (maxBatchInstancePercent: 20%)
   - Enable automatic OS upgrades: **Yes**
6. **Tags** → **Review + create** → **Create**

### Step 6.3 — Create App Tier VM Scale Set

Repeat Step 6.2 with these changes:
- Name: `ent-vmss-app-prod`
- VNet: `ent-vnet-app-prod`, Subnet: `snet-app`
- NSG: `ent-nsg-app-prod`
- Load balancer: `ent-lb-app-prod`, Backend pool: `app-backend-pool`
- Same scaling and zone configuration

### Step 6.4 — Configure VM Backup

1. Go to **ent-rsv-prod** → **Backup** → **+ Backup**
2. Where is your workload running: **Azure**
3. What do you want to back up: **Virtual machine**
4. Click **Backup**
5. Policy: select `vm-daily-backup`
6. Select VMs: choose the web and app VMSS instances
7. **Enable backup**

---

## Phase 7: Monitoring

> **AZ-104 Domain**: Monitoring (10-15%)
> Log Analytics collects and analyzes telemetry from all Azure resources. Metric alerts trigger automated responses. VM Insights provides deep visibility into VM performance and dependencies.

### Step 7.1 — Create Log Analytics Workspace

1. Portal → **Log Analytics workspaces** → **Create**
2. **Basics**:
   - Resource group: `ent-rg-monitoring-prod`
   - Name: `ent-law-prod`
   - Region: East US 2
3. **Pricing tier**: Pay-as-you-go (default)
4. **Tags** → **Review + create** → **Create**

> Screenshot: `docs/screenshots/38-log-analytics.png`

### Step 7.2 — Configure Diagnostic Settings (All Resources)

For each major resource, enable diagnostic logging to Log Analytics:

1. Go to the resource → **Diagnostic settings** (left menu, under Monitoring) → **Add diagnostic setting**
2. Name: `diag-to-law`
3. Check all available log categories
4. Check **Send to Log Analytics workspace** → select `ent-law-prod`
5. **Save**

Do this for:
- `ent-vnet-hub-prod` (VNet)
- `ent-fw-prod` (Firewall — critical for traffic analysis)
- `ent-nsg-web-prod` and `ent-nsg-app-prod` (NSGs)
- `ent-lb-web-prod` and `ent-lb-app-prod` (Load balancers)
- `ent-kv-prod-*` (Key Vault — audit log for compliance)
- Storage account (blob read/write/delete logs)

### Step 7.3 — Create Metric Alerts

**Alert 1: High CPU on Web VMSS**
1. Portal → **Monitor** → **Alerts** → **Create** → **Alert rule**
2. Scope: `ent-vmss-web-prod`
3. Condition: **Percentage CPU** > 80% averaged over 5 minutes
4. Actions: **Create action group** → name: `ag-infra-alerts`
   - Notification type: **Email/SMS** → add your email
5. Alert rule name: `High CPU - Web VMSS`
6. Severity: **2 - Warning**
7. **Create**

**Alert 2: Firewall Health**
1. Scope: `ent-fw-prod`
2. Condition: **Firewall Health State** < 90% averaged over 5 minutes
3. Action group: `ag-infra-alerts`
4. Name: `Firewall Health Degraded`
5. Severity: **1 - Error**

**Alert 3: Key Vault Availability**
1. Scope: `ent-kv-prod-*`
2. Condition: **Overall Vault Availability** < 99% averaged over 15 minutes
3. Action group: `ag-infra-alerts`
4. Name: `Key Vault Availability Drop`
5. Severity: **2 - Warning**

### Step 7.4 — Enable VM Insights

1. Portal → **Monitor** → **Insights** → **Virtual Machines**
2. Click **Configure Insights**
3. Select the web and app VMSS
4. Data collection rule: **Create new**
   - Name: `dcr-vm-insights`
   - Log Analytics workspace: `ent-law-prod`
   - Enable processes and dependencies: **Yes**
5. **Configure**

### Step 7.5 — Enable NSG Flow Logs

1. Portal → **Network Watcher** → **NSG flow logs** → **Create**
2. Select NSG: `ent-nsg-web-prod`
3. Storage account: select your storage account
4. Retention: 30 days
5. Flow logs version: **Version 2**
6. **Traffic Analytics**: Enabled
   - Log Analytics workspace: `ent-law-prod`
   - Processing interval: **Every 10 minutes**
7. **Create**
8. Repeat for `ent-nsg-app-prod`

---

## Verification Checklist

After completing all phases, verify every resource in the portal:

| # | Resource | Portal Location | What to Check |
|---|---|---|---|
| 1 | Resource Groups | Home → Resource groups | 5 groups, all East US 2 |
| 2 | Entra Users | Entra ID → Users | 10 users with departments |
| 3 | Security Groups | Entra ID → Groups | 7 groups (6 static + 1 dynamic) |
| 4 | Custom RBAC Roles | Subscription → IAM → Roles | 3 custom roles |
| 5 | RBAC Assignments | Subscription → IAM → Role assignments | 6 group assignments |
| 6 | Azure Policies | Policy → Assignments | 5 policy assignments |
| 7 | Resource Locks | Each RG → Locks | 3 locks (2 delete, 1 read-only) |
| 8 | Hub VNet | ent-vnet-hub-prod → Subnets | 4 subnets with correct CIDRs |
| 9 | Spoke VNets | ent-vnet-web/app-prod | 1 subnet each |
| 10 | VNet Peering | ent-vnet-hub-prod → Peerings | 2 peerings, status: Connected |
| 11 | Azure Firewall | ent-fw-prod | Provisioned, public IP, rules |
| 12 | Azure Bastion | ent-bastion-prod | Connected to hub VNet |
| 13 | NSGs | ent-nsg-web/app-prod | Rules in priority order |
| 14 | Route Table | ent-rt-spoke-prod | 2 routes, 2 subnet associations |
| 15 | Public LB | ent-lb-web-prod | Frontend IP, backend pool, rules |
| 16 | Internal LB | ent-lb-app-prod | Private frontend, backend pool |
| 17 | DNS Zone | ent-prod.example.com | NS, A, CNAME, MX, TXT records |
| 18 | Private DNS | ent.internal.prod | A record, VNet links |
| 19 | Storage Account | entstprod* | GRS, versioning, soft delete |
| 20 | Blob Containers | Storage → Containers | 4 containers (private) |
| 21 | Lifecycle Policy | Storage → Lifecycle management | 4 rules |
| 22 | Key Vault | ent-kv-prod-* | RBAC mode, soft delete, purge protection |
| 23 | Managed Identities | 3 identities in security RG | Client ID visible |
| 24 | Recovery Vault | ent-rsv-prod | GRS, backup policy configured |
| 25 | Web VMSS | ent-vmss-web-prod | 2 instances, 3 zones, autoscale |
| 26 | App VMSS | ent-vmss-app-prod | 2 instances, 3 zones, autoscale |
| 27 | Log Analytics | ent-law-prod | Active, workspace ID |
| 28 | Diagnostic Settings | Each resource | Logs → Log Analytics |
| 29 | Metric Alerts | Monitor → Alerts | 3 alert rules |
| 30 | NSG Flow Logs | Network Watcher → Flow logs | 2 NSGs, Traffic Analytics on |

---

## Cost Estimate

All resources fit within the **$200 free trial credit** when deployed in a single region:

| Resource | Estimated Cost (30 days) |
|---|---|
| Azure Firewall (Standard) | ~$30/day = ~$90 (biggest cost) |
| Azure Bastion (Basic) | ~$5/day = ~$15 |
| 2x VMSS (Standard_B2s, 2 instances each) | ~$60 |
| Storage Account (GRS, minimal data) | ~$2 |
| Key Vault (Standard) | ~$0.03/operation |
| Load Balancers (2x Standard) | ~$18 |
| Log Analytics | Free tier up to 5GB/day |
| DNS Zones | ~$1 |
| **Total estimate** | **~$185-195** |

**Teardown when done**: Delete all 5 resource groups (remove locks first) to stop all charges immediately.

---

## Teardown Order

When you are done with the project, delete resources in this order to avoid dependency errors:

1. Remove resource locks first:
   - Each locked RG → **Locks** → Delete each lock

2. Delete resource groups (each deletion removes everything inside):
   - `ent-rg-compute-prod` (VMs, backup vault)
   - `ent-rg-monitoring-prod` (Log Analytics, alerts)
   - `ent-rg-storage-prod` (storage account)
   - `ent-rg-security-prod` (Key Vault, identities)
   - `ent-rg-networking-prod` (VNets, firewall, bastion, LBs, DNS) — delete LAST because other resources may reference networking

3. For each RG: Go to the resource group → **Delete resource group** → type the name to confirm → **Delete**

4. Clean up Entra ID (optional):
   - Delete test users: **Entra ID → Users** → select → **Delete**
   - Delete groups: **Entra ID → Groups** → select → **Delete**
   - Delete custom roles: **Subscription → IAM → Roles** → select custom roles → **Delete**
   - Remove policy assignments: **Policy → Assignments** → select → **Delete assignment**
