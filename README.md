# Multi-Cloud Identity Federation with Kubernetes Access Management

A production-pattern lab that provisions three Kubernetes clusters across **Azure AKS**, **AWS EKS**, and **GCP GKE** - all unified under a single identity plane via **Microsoft Entra ID**. Users authenticate once with their Active Directory credentials and are granted role-based access across all three clusters automatically, with no per-cloud password or token management.

> **The Problem:** Enterprises with multiple cloud providers end up maintaining separate identity systems for each platform. Users juggle multiple passwords, security teams can't enforce consistent policies, and when someone leaves the company, IT must revoke access on every platform individually — a process that frequently fails.

> **The Solution:** A hub identity federation architecture. On-premises Active Directory is the single source of truth. Microsoft Entra ID acts as the central identity hub, syncing users via Entra Connect. From Entra ID, identity is federated outward to Kubernetes clusters on Azure (native), AWS (SAML), and GCP (OIDC). Each cluster enforces RBAC using AD security group memberships. One identity, three clouds, zero duplicate accounts.

---

## Demo

| Azure AKS | AWS EKS | GCP GKE |
|---|---|---|
| ! | ![AWS Dashboard](screenshots/aws-dashboard.png) | ![GCP Dashboard](screenshots/gcp-dashboard.png) |

Each dashboard shows the authenticated user's identity, their RBAC role (Admin or Developer), and which cloud the app is running on - all controlled by a single Active Directory group membership.

---

## Architecture Diagram 

[Architecture Diagram](screenshots/arch.png)


## Table of Contents

- [Prerequisites](#prerequisites)
- [Folder Structure](#folder-structure)
- [Phase 1 — On-Premises Setup](#phase-1--on-premises-setup)
  - [Step 1: Hyper-V Network Adapters](#step-1-hyper-v-network-adapters)
  - [Step 2: Domain Controller (DC01)](#step-2-domain-controller-dc01)
  - [Step 3: Active Directory — OUs, Groups, Users](#step-3-active-directory--ous-groups-users)
  - [Step 4: DHCP](#step-4-dhcp)
  - [Step 5: Member Server (MS01)](#step-5-member-server-ms01)
  - [Step 6: Windows Client (CLIENT01)](#step-6-windows-client-client01)
- [Phase 2 — Azure Tenant and Entra Connect](#phase-2--azure-tenant-and-entra-connect)
  - [Step 7: Azure Account and Tenant](#step-7-azure-account-and-tenant)
  - [Step 8: UPN Suffix Configuration](#step-8-upn-suffix-configuration)
  - [Step 9: Install Entra Connect](#step-9-install-entra-connect)
  - [Step 10: Verify Sync](#step-10-verify-sync)
- [Phase 3 — Cloud Infrastructure with Terraform](#phase-3--cloud-infrastructure-with-terraform)
  - [Step 11: Install Prerequisites](#step-11-install-prerequisites)
  - [Step 12: Configure Terraform Variables](#step-12-configure-terraform-variables)
  - [Step 13: Deploy All Three Clouds](#step-13-deploy-all-three-clouds)
  - [Step 14: Connect kubectl to All Clusters](#step-14-connect-kubectl-to-all-clusters)
- [Phase 4 — Kubernetes App, RBAC, and OAuth2 Proxy](#phase-4--kubernetes-app-rbac-and-oauth2-proxy)
  - [Step 15: Configure Entra ID App Registration](#step-15-configure-entra-id-app-registration)
  - [Step 16: AWS SAML Federation](#step-16-aws-saml-federation)
  - [Step 17: GCP Workload Identity Federation](#step-17-gcp-workload-identity-federation)
  - [Step 18: Deploy RBAC and App](#step-18-deploy-rbac-and-app)
  - [Step 19: Deploy OAuth2 Proxy with TLS](#step-19-deploy-oauth2-proxy-with-tls)
- [Phase 5 — Testing](#phase-5--testing)
- [Key Learnings](#key-learnings)
- [Technology Stack](#technology-stack)
- [Networking Summary](#networking-summary)
- [Cleanup](#cleanup)

---

## Prerequisites

- Windows machine with **Hyper-V** enabled (for Sandbox VMs)
- Windows Server 2022 ISO (for DC, member server, and client VMs)
- **Azure** account (pay-as-you-go or free trial)
- **AWS** account (free tier eligible)
- **GCP** account ($300 free credits for 90 days)
- Installed on your local machine:
  - [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
  - [AWS CLI](https://aws.amazon.com/cli/) — `aws configure`
  - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — `az login`
  - [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) — `gcloud auth login`
  - [kubectl](https://kubernetes.io/docs/tasks/tools/)
  - [kubelogin](https://github.com/Azure/kubelogin) (for AKS Entra ID auth)
  - [gke-gcloud-auth-plugin](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin) (for GKE auth)

---

## Folder Structure

```
hybrid-cloud-identity/
│
├── main.tf                    # Root module — calls aws, azure, gcp modules
├── providers.tf               # Terraform provider config (AWS, AzureRM, Google, TLS)
├── variables.tf               # All input variables (regions, tenant IDs, project IDs)
├── outputs.tf                 # Cluster names, endpoints, kubeconfig commands
├── terraform.tfvars           # Your actual values (gitignored)
├── terraform.tfvars.example   # Safe-to-commit template
├── .terraform.lock.hcl        # Provider version lock (commit this)
├── .gitignore
│
├── modules/
│   ├── aws/
│   │   ├── main.tf            # VPC, subnets, NAT, security groups, EKS, OIDC provider
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── azure/
│   │   ├── main.tf            # Resource group, VNet, AKS with Entra ID RBAC
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── gcp/
│       ├── main.tf            # VPC, Cloud Router/NAT, GKE private cluster, Workload Identity
│       ├── variables.tf
│       └── outputs.tf
│
└── k8s/
    ├── rbac.yaml              # ClusterRoles + ClusterRoleBindings (Entra ID group OIDs)
    ├── app-deployment.yaml    # Namespace, nginx-dashboard Deployment
    ├── app-service.yaml       # ClusterIP + LoadBalancer services
    ├── configmap.yaml         # HTML dashboard variants per cloud
    ├── index.html             # Dashboard source (patched per cluster via sed)
    └── oauth2-proxy.yaml      # OAuth2 Proxy Deployment (OIDC, TLS, Entra ID)
```

---

## Phase 1 — On-Premises Setup

### Step 1: Hyper-V Network Adapters

> **NOTE:** Each VM requires **two network adapters** — one on the NAT switch for internet access and one on the Private switch for internal domain traffic. Initially, only one adapter was attached per VM. Adding the second adapter requires shutting down each VM, adding hardware through Hyper-V settings, and configuring static IPs on the private adapter while leaving the NAT adapter on DHCP.

**Why two adapters?** This mirrors real enterprise network segmentation. Internal domain traffic (AD authentication, DNS, DHCP) stays on the private network. Internet traffic (cloud sync, browser access) goes through the NAT adapter. Companies do this with VLANs and firewalls — your lab replicates the same principle with two virtual switches.

For each VM (DC01, MS01, CLIENT01):

1. Shut down the VM in Hyper-V Manager
2. Right-click the VM → **Settings**
3. Click **Add Hardware** → **Network Adapter** → **Add**
4. Set one adapter to **NAT Network**, the other to **Private-No Internet**
5. Click **OK**

Each VM should have:
```
Network Adapter 1  →  NAT Network       (internet)
Network Adapter 2  →  Private-No Internet (domain/lab)
```

### Step 2: Domain Controller (DC01)

Boot up the DC VM and open PowerShell.

**Identify and rename network adapters:**
```powershell
ipconfig /all
# NAT adapter will have a 192.168.x.x address from DHCP
# Private adapter will have a 169.254.x.x APIPA address (no DHCP)

Rename-NetAdapter -Name "Ethernet 3" -NewName "NAT"
Rename-NetAdapter -Name "Ethernet 4" -NewName "Private"
```
> Adapter names may differ — check your `ipconfig /all` output and adjust.

**Set static IP on Private adapter:**
```powershell
New-NetIPAddress -InterfaceAlias "Private" -IPAddress 10.10.0.10 -PrefixLength 16
Set-DnsClientServerAddress -InterfaceAlias "Private" -ServerAddresses 127.0.0.1
```

> **Do NOT set a default gateway on the Private adapter.** There is no router on the private network. Having two gateways causes Windows to randomly route internet traffic through the wrong adapter, breaking connectivity.

**Rename the computer:**
```powershell
Rename-Computer -NewName "DC01" -Restart
```

**Install Active Directory Domain Services:**
```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
```

**Promote to domain controller:**
```powershell
Install-ADDSForest -DomainName "corp.local" -DomainNetBIOSName "CORP" -InstallDns:$true -Force:$true
```
- It will ask for a Safe Mode Administrator Password — pick something memorable
- The server reboots automatically
- After reboot, login changes to `CORP\Administrator`

**Verify DNS is working:**
```powershell
nslookup corp.local 10.10.0.10
```
You should see it resolve to 10.10.0.10.

You can also verify in the GUI: Start → type `dnsmgmt.msc` → Expand DC01 → Forward Lookup Zones → you should see `corp.local` with A records and SRV records.

### Step 3: Active Directory — OUs, Groups, Users

On DC01, open **Active Directory Users and Computers** (`dsa.msc`) or use PowerShell:

**Create organizational units:**
```powershell
New-ADOrganizationalUnit -Name "HybridCloud" -Path "DC=corp,DC=local"
New-ADOrganizationalUnit -Name "Users" -Path "OU=HybridCloud,DC=corp,DC=local"
New-ADOrganizationalUnit -Name "Groups" -Path "OU=HybridCloud,DC=corp,DC=local"
```

**Create security groups:**
```powershell
New-ADGroup -Name "Cloud-Admins" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=HybridCloud,DC=corp,DC=local"
New-ADGroup -Name "Cloud-Developers" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=HybridCloud,DC=corp,DC=local"
```

**Create test users:**
```powershell
New-ADUser -Name "John Smith" -SamAccountName "john" -UserPrincipalName "john@corp.local" -Path "OU=Users,OU=HybridCloud,DC=corp,DC=local" -AccountPassword (ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force) -Enabled $true

New-ADUser -Name "Sarah Jones" -SamAccountName "sarah" -UserPrincipalName "sarah@corp.local" -Path "OU=Users,OU=HybridCloud,DC=corp,DC=local" -AccountPassword (ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force) -Enabled $true

New-ADUser -Name "Mike Chen" -SamAccountName "mike" -UserPrincipalName "mike@corp.local" -Path "OU=Users,OU=HybridCloud,DC=corp,DC=local" -AccountPassword (ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force) -Enabled $true
```

**Add users to groups:**
```powershell
Add-ADGroupMember -Identity "Cloud-Admins" -Members "sarah"
Add-ADGroupMember -Identity "Cloud-Developers" -Members "john","mike"
```

**Result:**
```
OU=HybridCloud
  ├── OU=Users
  │     ├── John Smith   → Cloud-Developers
  │     ├── Sarah Jones  → Cloud-Admins
  │     └── Mike Chen    → Cloud-Developers
  └── OU=Groups
        ├── Cloud-Admins
        └── Cloud-Developers
```

### Step 4: DHCP

On DC01:

```powershell
Install-WindowsFeature DHCP -IncludeManagementTools
Add-DhcpServerInDC -DnsName "DC01.corp.local" -IPAddress 10.10.0.10
```

Then configure the scope in the GUI (`dhcpmgmt.msc`):

1. Expand DC01 → right-click **IPv4** → **New Scope**
2. Scope Name: `Lab Network`
3. IP Range: Start `10.10.0.100`, End `10.10.0.200`, Subnet mask `255.255.0.0`
4. Exclusions: skip
5. Lease duration: default (8 days)
6. Configure DHCP options: **Yes**
7. Router/Gateway: **skip** (no gateway on private network)
8. DNS: Parent domain `corp.local`, Server `DC01.corp.local` → Resolve → should show `10.10.0.10` → Add
9. WINS: skip
10. Activate scope: **Yes**

### Step 5: Member Server (MS01)

> **Important:** If your VMs were cloned from the same image, you must run sysprep first to generate a unique SID: `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /reboot`

After sysprep/OOBE, configure networking:

```powershell
# Identify and rename adapters (check ipconfig /all first)
Rename-NetAdapter -Name "Ethernet 3" -NewName "NAT"
Rename-NetAdapter -Name "Ethernet 4" -NewName "Private"

# Static IP on private adapter — no gateway
New-NetIPAddress -InterfaceAlias "Private" -IPAddress 10.10.0.11 -PrefixLength 16
Set-DnsClientServerAddress -InterfaceAlias "Private" -ServerAddresses 10.10.0.10

# Join domain and rename
Add-Computer -DomainName "corp.local" -NewName "MS01" -Credential CORP\Administrator -Restart
```

After reboot, log in as `CORP\Administrator`.

### Step 6: Windows Client (CLIENT01)

> Run sysprep if cloned from the same image (same as MS01).

```powershell
# Rename adapters
Rename-NetAdapter -Name "Ethernet 3" -NewName "NAT"
Rename-NetAdapter -Name "Ethernet 4" -NewName "Private"

# Client uses DHCP — just set DNS to DC01
Set-DnsClientServerAddress -InterfaceAlias "Private" -ServerAddresses 10.10.0.10

# Join domain
Add-Computer -DomainName "corp.local" -NewName "CLIENT01" -Credential CORP\Administrator -Restart
```

**Test:** After reboot, log in as `CORP\john` with password `P@ssw0rd123`. If John can log in, your entire on-prem domain is working.

**On-prem status at this point:**
```
DC01 ✓       → AD DS, DNS, DHCP, Users, Groups (10.10.0.10)
MS01 ✓       → Domain joined, ready for Entra Connect (10.10.0.11)
CLIENT01 ✓   → Domain joined, test workstation (DHCP)
```

---

## Phase 2 — Azure Tenant and Entra Connect

### Step 7: Azure Account and Tenant

1. Go to [azure.microsoft.com/free](https://azure.microsoft.com/en-us/free/) — use a **personal email** (not a school email, as university tenants may restrict your admin capabilities)
2. Create a pay-as-you-go or free trial subscription
3. Go to [entra.microsoft.com](https://entra.microsoft.com) → note your tenant domain (e.g., `YourName.onmicrosoft.com`)

**Create a dedicated admin account** (important if you signed up with Google SSO):

1. Entra admin center → **Identity** → **Users** → **+ New user** → **Create new user**
2. Username: `admin@YourTenant.onmicrosoft.com`
3. Name: `Sync Admin`
4. Set a password manually
5. **Assignments** → **+ Add role** → **Global Administrator**
6. Click **Create**

> **Why?** If you created your Azure account using Google SSO (Sign in with Google), there is no password for Entra Connect to use. Entra Connect requires username + password authentication. Creating a native Entra ID admin account solves this.

### Step 8: UPN Suffix Configuration

On **DC01**, add the cloud UPN suffix to your AD forest:

**GUI method:**
1. Open `domain.msc` (Active Directory Domains and Trusts)
2. Right-click the top node → **Properties**
3. Add: `YourTenant.onmicrosoft.com` → click **Add** → **OK**

**PowerShell method:**
```powershell
Get-ADForest | Set-ADForest -UPNSuffixes @{Add="YourTenant.onmicrosoft.com"}
```

**Update each user's UPN:**

GUI: Active Directory Users and Computers → each user → Account tab → change dropdown from `@corp.local` to `@YourTenant.onmicrosoft.com`

PowerShell:
```powershell
Set-ADUser -Identity john -UserPrincipalName "john@YourTenant.onmicrosoft.com"
Set-ADUser -Identity sarah -UserPrincipalName "sarah@YourTenant.onmicrosoft.com"
Set-ADUser -Identity mike -UserPrincipalName "mike@YourTenant.onmicrosoft.com"
```

**Verify:**
```powershell
Get-ADUser -Filter * -SearchBase "OU=Users,OU=HybridCloud,DC=corp,DC=local" | Select Name, UserPrincipalName
```

> **Why do this?** Entra ID doesn't know what `corp.local` is — it's a private, non-routable domain. The cloud UPN suffix tells Entra Connect how to map on-prem users to cloud identities. John can still log in locally as `CORP\john`. The UPN is only his cloud-facing identity.

### Step 9: Install Entra Connect

On **MS01** (not DC01 — Microsoft recommends installing Entra Connect on a separate server):

1. Disable IE Enhanced Security first:
```powershell
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0
```

2. Open Edge and go to [entra.microsoft.com](https://entra.microsoft.com)
3. Navigate to **Identity** → **Hybrid management** → **Microsoft Entra Connect** → **Connect Sync**
4. Download the installer

5. Run the installer → click **Customize** (not Express Settings)
6. Click **Install** on the first screen
7. Select **Password Hash Synchronization** → Next
8. **Entra ID credentials:** `admin@YourTenant.onmicrosoft.com` (the account you created in Step 7)

> **CRITICAL:** Use the same UPN in both the username field AND the login popup. Do not use your personal Gmail/Outlook email — use the native Entra ID admin account. This is the most common failure point.

9. **AD credentials:** select **Use existing AD account** → `CORP\Administrator`
10. Domain/OU Filtering: check only the **HybridCloud** OU
11. Click through remaining screens → **Install**

### Step 10: Verify Sync

Wait 2-3 minutes after install, then force a sync:

```powershell
Start-ADSyncSyncCycle -PolicyType Initial
```

Go to Azure portal → **Entra ID** → **Users**. You should see John Smith, Sarah Jones, and Mike Chen listed alongside your admin account.

---

## Phase 3 — Cloud Infrastructure with Terraform

### Step 11: Install Prerequisites

On your local machine (not the VMs):

```powershell
# Verify all tools
terraform --version
aws sts get-caller-identity
az account show
gcloud config list
kubectl version --client
```

Authenticate each CLI:
```powershell
aws configure                              # Enter access key, secret, region
az login                                   # Browser login
gcloud auth login                          # Browser login
gcloud auth application-default login      # For Terraform
```

Enable required GCP APIs:
```powershell
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
```

### Step 12: Configure Terraform Variables

```powershell
cd hybrid-cloud-identity
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:
```hcl
project_name = "hybrid-cloud-identity"
environment  = "lab"

# From: az account show
entra_tenant_id       = "your-tenant-id"
azure_subscription_id = "your-subscription-id"
entra_domain          = "YourTenant.onmicrosoft.com"
azure_region          = "East US"
azure_resource_group_name = "hybrid-cloud-identity-rg"

# From: aws sts get-caller-identity
aws_region = "us-east-1"

# From: gcloud config get-value project
gcp_project_id = "your-project-id"
gcp_region     = "us-central1"
```

### Step 13: Deploy All Three Clouds

```powershell
terraform init

# Deploy one at a time to catch errors early
terraform apply -target="module.azure" -auto-approve    # ~5-10 min
terraform apply -target="module.aws" -auto-approve      # ~10-15 min
terraform apply -target="module.gcp" -auto-approve      # ~10-20 min

# Verify
terraform output
```

### Step 14: Connect kubectl to All Clusters

```powershell
# Azure (admin context for RBAC setup)
az aks get-credentials --resource-group hybrid-cloud-identity-rg --name hybrid-cloud-identity-lab-aks --admin
C:\tools\kubelogin.exe convert-kubeconfig -l azurecli

# AWS
aws eks update-kubeconfig --region us-east-1 --name hybrid-cloud-identity-lab-eks

# GCP
gcloud config set project your-project-id
gcloud container clusters get-credentials hybrid-cloud-identity-lab-gke --region us-central1

# Verify all three
kubectl config get-contexts
```

---

## Phase 4 — Kubernetes App, RBAC, and OAuth2 Proxy

### Step 15: Configure Entra ID App Registration

1. Go to [entra.microsoft.com](https://entra.microsoft.com) → **Identity** → **Applications** → **App registrations**
2. **+ New registration** → Name: `Hybrid Cloud Dashboard` → Single tenant → **Register**
3. Copy the **Application (client) ID**
4. **Certificates & secrets** → **+ New client secret** → copy the **Value** immediately
5. **Token configuration** → **+ Add groups claim** → select **Security groups** → **Add**
6. **API permissions** → **+ Add a permission** → **Microsoft Graph** → **Delegated** → add `openid`, `profile`, `email` → **Grant admin consent**
7. **Manifest** → find `"redirectUris"` under `"web"` → add your cluster URLs:
```json
"redirectUris": [
    "https://YOUR-AKS-IP/oauth2/callback",
    "https://YOUR-EKS-HOSTNAME/oauth2/callback",
    "https://YOUR-GKE-IP/oauth2/callback"
]
```
> The manifest edit is needed because the UI blocks HTTP URIs. HTTPS with self-signed certs works through the manifest.

8. Assign users: **Enterprise applications** → **Hybrid Cloud Dashboard** → **Users and groups** → add John, Sarah, Mike individually

> **Note:** Entra ID free tier does not support group assignment to enterprise apps. Assign users individually. In production with a paid tier, you would assign groups instead.

### Step 16: AWS SAML Federation

1. In Entra admin center → **Enterprise applications** → **+ New application** → search **AWS IAM Identity Center** → **Create**
2. **Single sign-on** → **SAML** → Edit **Basic SAML Configuration**:
   - Identifier: `https://signin.aws.amazon.com/saml`
   - Reply URL: `https://signin.aws.amazon.com/saml`
3. Download **Federation Metadata XML** from the SAML Certificates section
4. Assign John, Sarah, Mike to the app

In **AWS Console** → **IAM**:

5. **Identity providers** → **Add provider** → SAML → Name: `EntraID` → upload the metadata XML
6. **Roles** → **Create role** → SAML 2.0 federation → select EntraID → Condition: `SAML:aud` / `StringEquals` / `https://signin.aws.amazon.com/saml`
   - Role 1: `EntraID-Cloud-Admins` → attach **AdministratorAccess**
   - Role 2: `EntraID-Cloud-Developers` → attach **ReadOnlyAccess**

### Step 17: GCP Workload Identity Federation

```powershell
# Create workload identity pool
gcloud iam workload-identity-pools create entra-id-pool --location="global" --display-name="Entra ID Pool" --project="your-project-id"

# Create OIDC provider
gcloud iam workload-identity-pools providers create-oidc entra-id-provider --location="global" --workload-identity-pool="entra-id-pool" --issuer-uri="https://login.microsoftonline.com/YOUR-TENANT-ID/v2.0" --allowed-audiences="api://YOUR-APP-CLIENT-ID" --attribute-mapping="google.subject=assertion.sub,attribute.groups=assertion.groups" --project="your-project-id"
```

Also register a separate app in Entra ID for GCP:
1. **App registrations** → **+ New registration** → Name: `GCP Workload Identity` → Single tenant → **Register**
2. **Token configuration** → **+ Add groups claim** → **Security groups**
3. **Expose an API** → Set Application ID URI to `api://YOUR-APP-CLIENT-ID` → Add scope `access`

### Step 18: Deploy RBAC and App

Get your Entra ID group Object IDs:
```powershell
az ad group show --group "Cloud-Admins" --query "id" --output tsv
az ad group show --group "Cloud-Developers" --query "id" --output tsv
```

Update `k8s/rbac.yaml` with the real group Object IDs, then deploy to all clusters:

```powershell
# For each cluster context:
kubectl apply -f k8s/rbac.yaml --context <context-name>
kubectl apply -f k8s/app-deployment.yaml --context <context-name>
kubectl apply -f k8s/app-service.yaml --context <context-name>
```

Get external IPs:
```powershell
kubectl get svc -n hybrid-cloud-app --context <context-name>
```

### Step 19: Deploy OAuth2 Proxy with TLS

**Generate self-signed TLS cert per cluster** (example for one IP):
```powershell
$ip = "YOUR-CLUSTER-IP"
$cfg = @"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $ip
[v3_req]
subjectAltName = IP:$ip
"@
$cfg | Out-File -Encoding ascii /tmp/cert.cnf
openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -config /tmp/cert.cnf

kubectl create secret tls oauth2-proxy-tls --cert=/tmp/tls.crt --key=/tmp/tls.key -n hybrid-cloud-app --context <context>
```

**Create OAuth2 Proxy secrets:**
```powershell
$COOKIE_SECRET = openssl rand -hex 16

kubectl create secret generic oauth2-proxy-secret --from-literal=client-id=YOUR-CLIENT-ID --from-literal=client-secret=YOUR-CLIENT-SECRET --from-literal=cookie-secret=$COOKIE_SECRET -n hybrid-cloud-app --context <context>

kubectl create configmap oauth2-proxy-config --from-literal=redirect-url=https://YOUR-CLUSTER-IP/oauth2/callback -n hybrid-cloud-app --context <context>
```

**Deploy OAuth2 Proxy:**
```powershell
kubectl apply -f k8s/oauth2-proxy.yaml --context <context>
```

**Create cloud-specific dashboard ConfigMaps:**
```powershell
# Azure
kubectl create configmap cloud-dashboard --from-literal=index.html="$(sed 's/Local Preview/Azure AKS/' k8s/index.html)" -n hybrid-cloud-app --context <aks-context>

# AWS
kubectl create configmap cloud-dashboard --from-literal=index.html="$(sed 's/Local Preview/AWS EKS/' k8s/index.html)" -n hybrid-cloud-app --context <eks-context>

# GCP
kubectl create configmap cloud-dashboard --from-literal=index.html="$(sed 's/Local Preview/GCP GKE/' k8s/index.html)" -n hybrid-cloud-app --context <gke-context>
```

Repeat TLS cert generation, secrets, and deployment for all three clusters.

---

## Phase 5 — Testing

1. On CLIENT01, log in as `CORP\john`
2. Open browser and visit `https://YOUR-AKS-IP`
3. Accept the certificate warning (self-signed)
4. Entra ID login page appears → sign in as `john@YourTenant.onmicrosoft.com`
5. Dashboard shows: Azure AKS, John's email, Developer (Read-Only)
6. Visit AWS and GCP URLs — SSO session means no re-login needed
7. Sign out → sign in as Sarah → shows Admin (Full Access)

---

## Key Learnings

### 1. UPN Suffix Mismatch for Cloud Sync

Active Directory users were created with `@corp.local` UPN suffixes, which cannot be synchronized to Entra ID because `.local` is a non-routable private domain. The forest required an alternative UPN suffix matching the Azure tenant domain (`Mahadikvallabh587gmail.onmicrosoft.com` — the UPN is long because I used the free pre-defined domain by Microsoft and did not buy a custom domain; it would be much shorter like `hybridcorp.com` if I did). This was added through Active Directory Domains and Trusts, and each user's UPN was manually updated through the Account tab in their properties.

### 2. Entra Connect Tenant Mismatch

The first several Entra Connect installation attempts failed with error AADSTS700016. The root cause was that the installer was using a personal Gmail account instead of the tenant-specific admin account. The installer was redirecting through Google's identity provider rather than Entra ID's own login flow. After creating a native Entra ID admin account and using its full UPN (`admin@Mahadikvallabh587gmail.onmicrosoft.com`) in both the username field and the popup login, the configuration succeeded. **Key takeaway: USE THE SAME UPN IN BOTH THE USERNAME FIELD AND THE LOGIN POPUP.**

### 3. Entra ID Free Tier Group Assignment Limitation

The Entra ID free tier does not support assigning security groups to enterprise applications. When configuring the AWS SAML federation app, only individual user assignment was available. The RBAC logic on the Kubernetes side still uses group Object IDs from the token claims, so permission enforcement was unaffected — but in the real world, enterprises use paid tiers where group assignment works. Without group assignment at scale, managing hundreds of users per application becomes impractical.

### 4. HTTPS Requirement for OAuth2 Proxy Redirect URIs

Entra ID's app registration UI blocks HTTP redirect URIs (requiring HTTPS or localhost). The initial OAuth2 Proxy configuration used plain HTTP, causing authentication failures (ERROR 500). Self-signed TLS certificates were generated for each cluster's external IP using OpenSSL with Subject Alternative Name (SAN) extensions. The certificates were stored as Kubernetes TLS secrets and mounted into the OAuth2 Proxy pods. **This is only because I don't have an SSL certificate for my demo application and a proper domain.** In production, you'd use a real domain with certificates from Let's Encrypt or a commercial CA. It was fun to learn that something like this exists and how the TLS handshake works at the infrastructure level.

---

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| Infrastructure as Code | Terraform >= 1.5 | Provision all cloud resources declaratively |
| Cloud — Azure | AKS | Kubernetes with native Entra ID RBAC |
| Cloud — AWS | EKS | Kubernetes with OIDC provider for Entra ID |
| Cloud — GCP | GKE (private cluster) | Kubernetes with Workload Identity |
| Identity Provider | Microsoft Entra ID | SSO, OIDC tokens, group membership claims |
| Auth Gateway | oauth2-proxy v7+ | Enforces Entra ID login, manages sessions |
| TLS | Self-signed certs (OpenSSL) | HTTPS with IP SANs |
| App Server | nginx:alpine | Serves the identity dashboard |
| Dashboard | Vanilla HTML/CSS/JS | Reads /oauth2/userinfo, displays role |
| On-Premises | Windows Server 2022 | AD DS, DNS, DHCP, Entra Connect |

---

## Networking Summary

| Resource | CIDR / Address |
|---|---|
| On-prem Private Network | `10.10.0.0/16` |
| DC01 (Domain Controller) | `10.10.0.10` |
| MS01 (Member Server) | `10.10.0.11` |
| CLIENT01 (Workstation) | DHCP (`10.10.0.100-200`) |
| Azure VNet | `10.30.0.0/16` |
| Azure AKS Subnet | `10.30.1.0/24` |
| AWS VPC | `10.20.0.0/16` |
| AWS Public Subnets | `10.20.101.0/24`, `10.20.102.0/24` |
| AWS Private Subnets | `10.20.1.0/24`, `10.20.2.0/24` |
| GCP Subnet | `10.40.0.0/24` |
| GCP Pods | `10.41.0.0/16` |
| GCP Services | `10.42.0.0/16` |

---

> **Tip:** Destroy infrastructure when not in use: `terraform destroy -auto-approve`

---

## Cleanup

```powershell
# Destroy all cloud infrastructure
cd hybrid-cloud-identity
terraform destroy -auto-approve

# Delete GCP workload identity pool
gcloud iam workload-identity-pools delete entra-id-pool --location="global" --project="your-project-id"

# Delete Entra ID app registrations (Azure portal → App registrations → delete)
# Delete AWS IAM roles and identity provider (AWS Console → IAM)
```

---

## License

This project is for educational purposes. Built as a final project for Systems Administration coursework.
