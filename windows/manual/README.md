# PQC PKI Lab — Manual Installation Guide

> **Purpose:** Step-by-step instructions to build the PQC PKI lab environment without
> using the automation scripts. Follow this guide to understand every configuration
> decision, or to verify that a scripted build produced the correct end state.
>
> **Covers:** Both **Azure** and **Hyper-V** deployment paths.
> **Environment:** 5-machine lab (Root CA, Domain Controller, Issuing CA, Web Server,
> Windows 11 client).

---

## 0. Prerequisites & OS Requirements

### Operating System Versions

| VM Role | Required OS | Minimum Patch |
|---------|------------|---------------|
| Root CA | **Windows Server 2025 GA** (Build 26100.x) | KB5099536 (build ≥ 26100.33158) |
| Domain Controller | Windows Server 2025 GA | KB5099536 |
| Issuing CA | Windows Server 2025 GA | KB5099536 |
| Web Server | Windows Server 2025 GA | KB5099536 |
| Test Client | **Windows 11 24H2 GA** (Build 26100.x) | KB5101650 (build ≥ 26100.8524) |

> **Alternative:** Windows Server vNext Insider Preview build 29550+ has all PQC features
> built-in — no KB patches required. The same configuration steps apply.

### Why KB5099536?

- **ML-DSA certificate issuance** (CA servers): requires KB5087539 or later. KB5099536
  supersedes KB5087539, so installing KB5099536 covers both capabilities.
- **ML-KEM hybrid TLS** (all machines): requires KB5099536 (July 14, 2026 Cumulative Update,
  OS Build 26100.33158). This is the single KB that enables the `Enable-TlsEccCurve`
  cmdlets and the `x25519_mlkem768` hybrid group.

### Patch Verification (run on each server after OS install)

Open PowerShell as Administrator on each VM:

```powershell
$build    = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
$revision = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
Write-Host "Build: $build.$revision"

# Expected: 26100.33158 or higher for GA path
# Expected: 29550 or higher for vNext path

# Also confirm via hotfix list:
Get-HotFix | Where-Object HotFixID -in "KB5099536","KB5087539" | Select-Object HotFixID, InstalledOn
```

**Expected output (GA path):** Build `26100.33158` or higher, `KB5099536` listed.

---

## 1. Network Layout

Both paths use the same logical IP assignments:

| VM | Hostname | IP Address |
|----|----------|-----------|
| Root CA | `rootca` | Azure: `10.10.1.20` / Hyper-V: `10.10.0.20` |
| Domain Controller | `dc01` | Azure: `10.10.1.10` / Hyper-V: `10.10.0.10` |
| Issuing CA | `issuingca` | Azure: `10.10.1.30` / Hyper-V: `10.10.0.30` |
| Web Server | `webserver01` | Azure: `10.10.1.40` / Hyper-V: `10.10.0.40` |
| Win11 Client | `win11client` | Azure: `10.10.1.50` / Hyper-V: `10.10.0.50` |

**Domain:** `pqclab.local` / NetBIOS: `PQCLAB`

---

## 2. Platform Setup

### Path A — Azure

#### 2A-1. Resource Group and Networking

```powershell
# Run from your workstation (Azure CLI must be installed and logged in)
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Create resource group
az group create --name "rg-pqc-lab" --location "eastus"

# Get your current public IP (for NSG rules)
$myIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip

# Create NSG
az network nsg create --resource-group "rg-pqc-lab" --name "pqclab-nsg" --location "eastus"

# NSG rules
az network nsg rule create --resource-group "rg-pqc-lab" --nsg-name "pqclab-nsg" `
    --name "Allow-VNet-Internal" --priority 900 --protocol "*" --direction Inbound `
    --source-address-prefixes "VirtualNetwork" --destination-address-prefixes "VirtualNetwork" `
    --destination-port-ranges "*" --access Allow

az network nsg rule create --resource-group "rg-pqc-lab" --nsg-name "pqclab-nsg" `
    --name "Allow-RDP-From-Admin" --priority 1000 --protocol Tcp --direction Inbound `
    --source-address-prefixes "$myIP/32" --destination-port-ranges 3389 --access Allow

az network nsg rule create --resource-group "rg-pqc-lab" --nsg-name "pqclab-nsg" `
    --name "Allow-HTTPS-Inbound" --priority 1010 --protocol Tcp --direction Inbound `
    --source-address-prefixes "$myIP/32" --destination-port-ranges 443 --access Allow

# Create VNet and subnet
az network vnet create --resource-group "rg-pqc-lab" --name "pqclab-vnet" `
    --location "eastus" --address-prefixes "10.10.0.0/16" `
    --subnet-name "pqclab-subnet" --subnet-prefixes "10.10.1.0/24"

# Point VNet DNS to future DC IP (so domain-joined VMs resolve correctly)
az network vnet update --resource-group "rg-pqc-lab" --name "pqclab-vnet" `
    --dns-servers "10.10.1.10"
```

#### 2A-2. Create VMs

Repeat this block for each server VM, substituting the name and private IP:

| VM | Name | Private IP |
|----|------|-----------|
| Root CA | `pqclab-rootca` | `10.10.1.20` |
| DC | `pqclab-dc` | `10.10.1.10` |
| Issuing CA | `pqclab-issuingca` | `10.10.1.30` |
| Web Server | `pqclab-webserver` | `10.10.1.40` |
| Win11 Client | `pqclab-win11client` | `10.10.1.50` |

```powershell
# Template — run once per VM (substitute $vmName and $privateIP)
$vmName    = "pqclab-rootca"    # change for each VM
$privateIP = "10.10.1.20"       # change for each VM
$rg        = "rg-pqc-lab"

az network public-ip create --resource-group $rg --name "$vmName-pip" `
    --sku Standard --allocation-method Static --location "eastus"

az network nic create --resource-group $rg --name "$vmName-nic" --location "eastus" `
    --vnet-name "pqclab-vnet" --subnet "pqclab-subnet" `
    --private-ip-address $privateIP --public-ip-address "$vmName-pip" `
    --network-security-group "pqclab-nsg"

# Server VMs — use Windows Server 2025 Datacenter image
# NOTE: For a fully patched GA image, you should pre-patch a base image or
# apply KB5099536 via Windows Update immediately after first boot.
az vm create --resource-group $rg --name $vmName --location "eastus" `
    --nics "$vmName-nic" `
    --image "MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest" `
    --size "Standard_B2ms" `
    --admin-username "labadmin" --admin-password "P@ssw0rd-PQCLab2026!" `
    --os-disk-size-gb 128 --storage-sku Premium_LRS

# For the Win11 client VM, use:
# --image "MicrosoftWindowsDesktop:Windows-11:win11-24h2-ent:latest"
```

> **After VM creation:** RDP into each server VM and run Windows Update until
> OS build reaches 26100.33158 or higher before proceeding.

---

### Path B — Hyper-V

#### 2B-1. Host Preparation

Run on the **Hyper-V host** as Administrator:

```powershell
# Enable Hyper-V if not already installed
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
# Restart required after enabling Hyper-V

# Create lab folder structure
New-Item -ItemType Directory -Force -Path "D:\HyperV\PQCLab"
New-Item -ItemType Directory -Force -Path "D:\HyperV\PQCLab\staging"
New-Item -ItemType Directory -Force -Path "D:\HyperV\BaseImages"

# Create internal switch for lab VMs
New-VMSwitch -Name "PQC-Lab-Switch" -SwitchType Internal

# Assign IP to host vNIC on the switch
$hostVnic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*PQC-Lab-Switch*" }
New-NetIPAddress -InterfaceIndex $hostVnic.ifIndex -IPAddress "10.10.0.1" -PrefixLength 24

# Create NAT for internet access from lab VMs
New-NetNat -Name "PQC-Lab-NAT" -InternalIPInterfaceAddressPrefix "10.10.0.0/24"
```

#### 2B-2. Prepare Gold VHDX

1. Download the **Windows Server 2025 Evaluation ISO** from the Microsoft Evaluation Center.
2. Create a new Hyper-V Gen2 VM (512MB RAM, 60GB VHD) and install from the ISO.
3. After OOBE completes, run Windows Update until build reaches **26100.33158** or higher.
4. Run Sysprep:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

5. Copy the resulting VHDX to `D:\HyperV\BaseImages\ws2025-26100.33158-gold.vhdx`.

Do the same for the **Windows 11 24H2** client VHDX, applying **KB5101650** before sysprep:
- Target path: `D:\HyperV\BaseImages\win11-26100-ga-gold.vhdx`

#### 2B-3. Create Lab VMs

```powershell
# Function to create a differencing-disk VM from the gold VHDX
function New-LabVm {
    param(
        [string]$Name,
        [string]$BaseVhdx,
        [string]$VmRootPath,
        [string]$SwitchName,
        [long]$MemGB = 4,
        [int]$CPU = 2
    )
    $vmFolder = Join-Path $VmRootPath $Name
    New-Item -ItemType Directory -Force -Path $vmFolder | Out-Null

    $diffVhd = Join-Path $vmFolder "$Name-os.vhdx"
    New-VHD -Path $diffVhd -ParentPath $BaseVhdx -Differencing | Out-Null

    $vm = New-VM -Name $Name -Generation 2 -Path $VmRootPath `
                 -MemoryStartupBytes ($MemGB * 1GB) -SwitchName $SwitchName
    Add-VMHardDiskDrive -VMName $Name -Path $diffVhd
    Set-VMProcessor -VMName $Name -Count $CPU
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                 -MinimumBytes (2GB) -MaximumBytes (8GB)
    Set-VMFirmware -VMName $Name -EnableSecureBoot On `
                   -SecureBootTemplate "MicrosoftWindows"
    return $vm
}

$base   = "D:\HyperV\BaseImages\ws2025-26100.33158-gold.vhdx"
$root   = "D:\HyperV\PQCLab"
$switch = "PQC-Lab-Switch"

New-LabVm -Name "pqc-rootca"    -BaseVhdx $base -VmRootPath $root -SwitchName $switch
New-LabVm -Name "pqc-dc01"      -BaseVhdx $base -VmRootPath $root -SwitchName $switch
New-LabVm -Name "pqc-issuingca" -BaseVhdx $base -VmRootPath $root -SwitchName $switch
New-LabVm -Name "pqc-web01"     -BaseVhdx $base -VmRootPath $root -SwitchName $switch

# Win11 client — different base VHDX
New-LabVm -Name "pqc-win11client" `
    -BaseVhdx "D:\HyperV\BaseImages\win11-26100-ga-gold.vhdx" `
    -VmRootPath $root -SwitchName $switch

# Start all VMs
"pqc-rootca","pqc-dc01","pqc-issuingca","pqc-web01","pqc-win11client" |
    ForEach-Object { Start-VM -Name $_ }
```

#### 2B-4. Configure Static IPs Inside Each VM

Connect to each VM via VM Connect and set a static IP. Repeat for each role:

```powershell
# On dc01 — run inside the VM via VM Connect
$nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress "10.10.0.10" `
    -PrefixLength 24 -DefaultGateway "10.10.0.1"
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses "127.0.0.1"
Rename-Computer -NewName "dc01" -Force; Restart-Computer -Force
```

| VM | Hostname | IP | Gateway | DNS |
|----|----------|----|---------|-----|
| pqc-rootca | `rootca` | `10.10.0.20` | `10.10.0.1` | `10.10.0.10` |
| pqc-dc01 | `dc01` | `10.10.0.10` | `10.10.0.1` | `127.0.0.1` |
| pqc-issuingca | `issuingca` | `10.10.0.30` | `10.10.0.1` | `10.10.0.10` |
| pqc-web01 | `webserver01` | `10.10.0.40` | `10.10.0.1` | `10.10.0.10` |
| pqc-win11client | `win11client` | `10.10.0.50` | `10.10.0.1` | `10.10.0.10` |

---

## 3. Domain Controller Setup

**Run on:** `dc01`  
**Method:** Console/RDP into the VM

### 3-1. Install AD DS Role

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -Confirm:$false
```

### 3-2. Promote to Domain Controller

```powershell
$secureSafe = ConvertTo-SecureString "P@ssw0rd-DSRM2026!" -AsPlainText -Force

Install-ADDSForest `
    -DomainName "pqclab.local" `
    -DomainNetbiosName "PQCLAB" `
    -InstallDns `
    -SafeModeAdministratorPassword $secureSafe `
    -Force
```

The VM will reboot automatically. Wait 2–3 minutes for AD DS to fully initialize.

### 3-3. Verify DC Health

After reboot, log in and run:

```powershell
Get-ADDomainController -Discover -Service PrimaryDC | Select-Object Name, Domain, Site
Get-Service ADWS, DNS, Netlogon | Select-Object Name, Status
```

**Expected:** All three services show `Running`.

### 3-4. Create CA Enrollment Service Account

```powershell
Import-Module ActiveDirectory
New-ADUser `
    -Name "svc-ca-enroll" `
    -SamAccountName "svc-ca-enroll" `
    -UserPrincipalName "svc-ca-enroll@pqclab.local" `
    -AccountPassword (ConvertTo-SecureString "P@ssw0rd-SvcCA2026!" -AsPlainText -Force) `
    -PasswordNeverExpires $true `
    -Enabled $true `
    -Description "Service account for CA auto-enrollment"
```

**End state check:** `Get-ADUser svc-ca-enroll` returns the user.

---

## 4. Root CA Setup (Standalone, ML-DSA-87)

**Run on:** `rootca`  
**Important:** The Root CA is **standalone** (not domain-joined). It should be taken
offline after the Issuing CA is signed.

### 4-1. Set Hostname

```powershell
Rename-Computer -NewName "rootca" -Force
Restart-Computer -Force
```

### 4-2. Install AD CS Role

```powershell
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools -Confirm:$false
```

### 4-3. Configure Standalone Root CA with ML-DSA-87

```powershell
# ML-DSA-87 key: 2592 bytes × 8 = 20736 bits
# HashAlgorithm MUST be NoHash — ML-DSA handles hashing internally
Install-AdcsCertificationAuthority `
    -CAType StandaloneRootCA `
    -CACommonName "PQCLab Root CA" `
    -KeyLength 20736 `
    -HashAlgorithm NoHash `
    -CryptoProviderName "ML-DSA:87#Microsoft Software Key Storage Provider" `
    -ValidityPeriod Years `
    -ValidityPeriodUnits 10 `
    -Force
```

### 4-4. Configure CRL Settings

```powershell
# Short CRL lifetime for test lab
certutil -setreg CA\CRLPeriodUnits 1
certutil -setreg CA\CRLPeriod "Weeks"
certutil -setreg CA\CRLDeltaPeriodUnits 0
certutil -setreg CA\CRLDeltaPeriod "Days"
certutil -setreg CA\ValidityPeriodUnits 5

Restart-Service certsvc
Start-Sleep -Seconds 5
certutil -crl
```

### 4-5. Export Root CA Certificate and CRL

```powershell
New-Item -ItemType Directory -Force -Path "C:\PKI-Export" | Out-Null

# Export Root CA certificate
certutil -ca.cert "C:\PKI-Export\RootCA.cer"

# Export CRL
$crl = Get-ChildItem "C:\Windows\system32\CertSrv\CertEnroll" -Filter "*.crl" | Select-Object -First 1
if ($crl) { Copy-Item $crl.FullName "C:\PKI-Export\RootCA.crl" }

# Verify
certutil -store Root "PQCLab Root CA"
```

**End state:** `C:\PKI-Export\RootCA.cer` and `C:\PKI-Export\RootCA.crl` exist.

### 4-6. Transfer Root CA Files to Issuing CA

You need to copy `RootCA.cer` and `RootCA.crl` from the Root CA to the Issuing CA's
`C:\PKI-Import\` folder. Options:

- **Azure:** Use RDP clipboard copy, or Azure Blob Storage as a relay (see scripts
  `03-config-rootca.ps1` and `03b-copy-certs-between-vms.ps1`).
- **Hyper-V:** Copy from host staging folder via PSSession:
  ```powershell
  # On the Hyper-V host
  $cred = Get-Credential   # local Administrator on rootca
  $session = New-PSSession -VMName "pqc-rootca" -Credential $cred
  Copy-Item -FromSession $session -Path "C:\PKI-Export\RootCA.cer" `
            -Destination "D:\HyperV\PQCLab\staging\RootCA.cer"
  Copy-Item -FromSession $session -Path "C:\PKI-Export\RootCA.crl" `
            -Destination "D:\HyperV\PQCLab\staging\RootCA.crl"
  Remove-PSSession $session
  ```

---

## 5. Issuing CA Setup (Enterprise Subordinate, ML-DSA-65)

**Run on:** `issuingca`  
**Prerequisite:** `RootCA.cer` and `RootCA.crl` are in `C:\PKI-Import\` on this VM.

### 5-1. Domain Join

```powershell
# Rename first
Rename-Computer -NewName "issuingca" -Force

# Join domain
$cred = New-Object System.Management.Automation.PSCredential(
    "PQCLAB\labadmin",
    (ConvertTo-SecureString "P@ssw0rd-PQCLab2026!" -AsPlainText -Force)
)
Add-Computer -DomainName "pqclab.local" -Credential $cred -Force -Restart
```

Wait 2 minutes for reboot and domain join to complete. Log back in as `PQCLAB\labadmin`.

### 5-2. Install AD CS Role

```powershell
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools -Confirm:$false
```

### 5-3. Import Root CA Trust

```powershell
New-Item -ItemType Directory -Force -Path "C:\PKI-Import" | Out-Null

# Add Root CA to Local Machine Trusted Roots
certutil -addstore Root "C:\PKI-Import\RootCA.cer"
certutil -addstore -enterprise Root "C:\PKI-Import\RootCA.cer"

# Publish Root CA CRL
certutil -addstore Root "C:\PKI-Import\RootCA.crl"
```

### 5-4. Configure Enterprise Subordinate CA with ML-DSA-65

```powershell
New-Item -ItemType Directory -Force -Path "C:\PKI-Export" | Out-Null

# ML-DSA-65 key: 1952 bytes × 8 = 15616 bits
Install-AdcsCertificationAuthority `
    -CAType EnterpriseSubordinateCA `
    -CACommonName "PQCLab Issuing CA" `
    -KeyLength 15616 `
    -HashAlgorithm NoHash `
    -CryptoProviderName "ML-DSA:65#Microsoft Software Key Storage Provider" `
    -OutputCertRequestFile "C:\PKI-Export\SubCA.req" `
    -Force
```

This generates `C:\PKI-Export\SubCA.req`. The CA service remains **offline** until
the Root CA signs this request.

### 5-5. Submit CSR to Root CA and Get Signed Certificate

Copy `SubCA.req` to the Root CA's `C:\PKI-Import\` folder, then **on the Root CA**:

```powershell
# Submit the CSR and get the RequestId
$submitOut = certutil -submit "C:\PKI-Import\SubCA.req"
$reqId = ($submitOut | Select-String "RequestId:" | ForEach-Object {
    ($_.ToString().Split(":")[1]).Trim().Split(" ")[0]
})
Write-Host "RequestId: $reqId"

# Approve and issue the certificate
certutil -resubmit $reqId

# Retrieve the signed certificate
certutil -retrieve $reqId "C:\PKI-Export\SubCA.cer"
```

Copy `SubCA.cer` back to the Issuing CA's `C:\PKI-Import\` folder.

### 5-6. Install Signed Certificate and Start CA Service

**On the Issuing CA:**

```powershell
# Install the signed certificate to complete CA setup
certreq -accept "C:\PKI-Import\SubCA.cer"

# Publish Root CA cert into AD (so domain computers automatically trust it via GPO)
certutil -dspublish -f "C:\PKI-Import\RootCA.cer" RootCA

# Start the CA service
Start-Service certsvc
Start-Sleep -Seconds 5

# Verify
Get-Service certsvc | Select-Object Name, Status
certutil -ping
```

**End state check:**  
- `Get-Service certsvc` → Status: `Running`  
- `certutil -ping` → `Server "PQCLab Issuing CA" ICertRequest2 interface is alive`

---

## 6. PQC Web Server Certificate Template

**Run on:** `issuingca`  
**Prerequisite:** Issuing CA is online and `certsvc` is running.

### 6-1. Create PQC Web Server Template in AD

```powershell
Import-Module ActiveDirectory

$configContext      = (Get-ADRootDSE).configurationNamingContext
$templateContainer  = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configContext"

# Check if template already exists
if (-not ([adsi]::Exists("LDAP://CN=PQCWebServer,$templateContainer"))) {

    # Copy the built-in Web Server template
    $source = [adsi]"LDAP://CN=WebServer,$templateContainer"
    $copy   = $source.psbase.CopyTo("LDAP://CN=PQCWebServer,$templateContainer")

    $copy.Put("cn",          "PQCWebServer")
    $copy.Put("displayName", "PQC Web Server")

    # Subject from request
    $copy.Put("msPKI-Certificate-Name-Flag", 1)

    # AT_SIGNATURE = 2 (required for ML-DSA — signature only, no encryption)
    $copy.Put("pKIDefaultKeySpec", 2)

    # ML-DSA-65 KSP
    $copy.Put("pKIDefaultCSPs", @("1,ML-DSA:65#Microsoft Software Key Storage Provider"))

    # ML-DSA-65 public key = 1952 bytes = 15616 bits
    $copy.Put("msPKI-Minimal-Key-Size", 15616)

    # 1-year validity, 6-week renewal window
    $copy.Put("pKIExpirationPeriod", [byte[]](0,64,57,135,46,225,254,255))
    $copy.Put("pKIOverlapPeriod",    [byte[]](0,128,166,10,255,222,255,255))

    # Server Authentication EKU only (no EFS, no email)
    $copy.Put("pKIExtendedKeyUsage", @("1.3.6.1.5.5.7.3.1"))

    # Private key flags: signature purpose only
    $copy.Put("msPKI-Private-Key-Flag", 0x00000110)

    $copy.SetInfo()
    Write-Host "Template 'PQCWebServer' created in AD."
} else {
    Write-Host "Template 'PQCWebServer' already exists."
}

# Grant Enroll permission to Domain Computers
$domainComputersSid = (Get-ADGroup "Domain Computers").SID
$acl         = ([adsi]"LDAP://CN=PQCWebServer,$templateContainer").psbase.ObjectSecurity
$accessRule  = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $domainComputersSid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"   # Certificate-Enrollment right
)
$acl.AddAccessRule($accessRule)
([adsi]"LDAP://CN=PQCWebServer,$templateContainer").psbase.CommitChanges()

# Publish template to the Issuing CA
Add-CATemplate -Name "PQCWebServer" -Force
Write-Host "Template published to CA."
```

**End state check:** `Get-CATemplate | Where-Object Name -eq 'PQCWebServer'` returns one result.

---

## 7. Web Server Setup (IIS + ML-DSA TLS Certificate)

**Run on:** `webserver01`  
**Prerequisite:** Domain is up; Issuing CA is online with `PQCWebServer` template published.

### 7-1. Rename and Domain Join

```powershell
Rename-Computer -NewName "webserver01" -Force

$cred = New-Object System.Management.Automation.PSCredential(
    "PQCLAB\labadmin",
    (ConvertTo-SecureString "P@ssw0rd-PQCLab2026!" -AsPlainText -Force)
)
Add-Computer -DomainName "pqclab.local" -Credential $cred -Force -Restart
```

Wait 2 minutes for reboot. Log back in as `PQCLAB\labadmin`.

### 7-2. Install IIS

```powershell
Install-WindowsFeature Web-Server, Web-Mgmt-Console -Confirm:$false

# Wait for AD CS enrollment service to be reachable
Start-Sleep -Seconds 30
```

### 7-3. Create Certificate Request INF File

Save the following as `C:\Temp\pqc-tls.inf`:

```ini
[Version]
Signature = "$Windows NT$"

[NewRequest]
Subject      = "CN=webserver01.pqclab.local"
KeyAlgorithm = ML-DSA
KeyLength    = 15616
HashAlgorithm = NoHash
MachineKeySet = True
RequestType  = PKCS10
KeySpec      = 2
ProviderName = "ML-DSA:65#Microsoft Software Key Storage Provider"
ProviderType = 0
SMIME        = FALSE
Silent       = TRUE

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1 ; Server Authentication

[RequestAttributes]
CertificateTemplate = PQCWebServer

[Extensions]
2.5.29.17 = "{text}dns=webserver01.pqclab.local&dns=webserver01"
```

### 7-4. Request, Submit, and Accept the TLS Certificate

```powershell
New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null

# Step 1: Generate the key and CSR
certreq -new "C:\Temp\pqc-tls.inf" "C:\Temp\pqc-tls.req"

# Step 2: Submit to Issuing CA and auto-enroll
# Replace "issuingca.pqclab.local\PQCLab Issuing CA" with your CA config string
certreq -submit -config "issuingca.pqclab.local\PQCLab Issuing CA" `
    "C:\Temp\pqc-tls.req" "C:\Temp\pqc-tls.cer"

# Step 3: Accept and install the signed certificate
certreq -accept "C:\Temp\pqc-tls.cer"
```

### 7-5. Bind Certificate to IIS HTTPS

```powershell
Import-Module WebAdministration

# Find the newly enrolled certificate
$cert  = Get-ChildItem "cert:\LocalMachine\My" |
         Where-Object { $_.Subject -match "webserver01" } |
         Select-Object -First 1
$thumb = $cert.Thumbprint

# Remove any existing HTTPS binding and recreate
Remove-WebBinding -Name "Default Web Site" -Protocol https -ErrorAction SilentlyContinue
New-WebBinding -Name "Default Web Site" -Protocol https -Port 443 `
    -HostHeader "webserver01.pqclab.local"

# Bind the ML-DSA certificate
$sslPath = "IIS:\SslBindings\0.0.0.0!443"
if (Test-Path $sslPath) { Remove-Item $sslPath -Force }
Get-Item "cert:\LocalMachine\My\$thumb" | New-Item $sslPath

Write-Host "IIS HTTPS bound to certificate: $thumb"
```

**End state check:**
- `Get-ChildItem cert:\LocalMachine\My | Select Subject, Thumbprint` shows `CN=webserver01.pqclab.local`
- `Invoke-WebRequest -Uri "https://webserver01.pqclab.local" -UseBasicParsing` returns HTTP 200
  (from a machine that trusts the Root CA)

---

## 8. Enable ML-KEM Hybrid TLS Key Exchange

ML-KEM (FIPS 203) enables post-quantum-safe **key exchange** in the TLS 1.3 handshake.
It is independent of the certificate's ML-DSA signature algorithm. **Both** the server
and client must enable the same hybrid groups.

Apply these steps on:
1. **webserver01** (TLS server — required)
2. **dc01** (optional — enables ML-KEM for LDAPS and other DC TLS services)
3. **win11client** (TLS client — required for negotiation to succeed)

### 8-1. Enable ML-KEM Hybrid Groups (PowerShell)

```powershell
# Enable the three ML-KEM hybrid groups
Enable-TlsEccCurve -Name "x25519_mlkem768"
Enable-TlsEccCurve -Name "secp256r1_mlkem768"
Enable-TlsEccCurve -Name "secp384r1_mlkem1024"

# Set priority order: ML-KEM hybrids first, classical fallbacks at end
Set-TlsEccCurve -Name @(
    "x25519_mlkem768",        # Best performance: X25519 + ML-KEM-768 (NIST Level 1)
    "secp256r1_mlkem768",     # Alternative: NIST P-256 + ML-KEM-768
    "secp384r1_mlkem1024",    # High-security: NIST P-384 + ML-KEM-1024 (NIST Level 5)
    "NistP384",               # Classical fallback
    "NistP256",               # Classical fallback
    "x25519"                  # Classical fallback
)

# Verify
Get-TlsEccCurve | Select-Object Name, Priority | Format-Table -AutoSize
```

### 8-2. Persist KEM Group Order in Registry

The registry entry ensures the group priority survives Group Policy refreshes:

```powershell
# IMPORTANT: This key uses REG_MULTI_SZ (-Type MultiString)
$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010003"
if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }

Set-ItemProperty -Path $regBase -Name "Functions" -Value @(
    "x25519_mlkem768",
    "secp256r1_mlkem768",
    "secp384r1_mlkem1024",
    "NistP384",
    "NistP256",
    "x25519"
) -Type MultiString
```

### 8-3. Ensure TLS 1.3 Is Enabled

ML-KEM operates exclusively over TLS 1.3. Explicitly enable it on both server and
client sides:

```powershell
# Server TLS 1.3
$serverKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server"
if (-not (Test-Path $serverKey)) { New-Item -Path $serverKey -Force | Out-Null }
Set-ItemProperty -Path $serverKey -Name "Enabled"          -Value 1 -Type DWord
Set-ItemProperty -Path $serverKey -Name "DisabledByDefault" -Value 0 -Type DWord

# Client TLS 1.3
$clientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
if (-not (Test-Path $clientKey)) { New-Item -Path $clientKey -Force | Out-Null }
Set-ItemProperty -Path $clientKey -Name "Enabled"          -Value 1 -Type DWord
Set-ItemProperty -Path $clientKey -Name "DisabledByDefault" -Value 0 -Type DWord
```

### 8-4. Enable Schannel Event Logging (Win11 Client Only)

This enables Event ID 36880 (TLS Session Established) in the System event log for
verification:

```powershell
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL" `
    -Name "EventLogging" -Value 7 -Type DWord -Force
```

### 8-5. Restart

```powershell
Restart-Computer -Force
```

ML-KEM groups are **not active until after restart**. Run this on each machine before
proceeding to the verification step.

---

## 9. Windows 11 Client Configuration

**Run on:** `win11client`

### 9-1. Set Static IP, Hostname, and DNS

```powershell
$nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress "10.10.0.50" `   # or 10.10.1.50 for Azure
    -PrefixLength 24 -DefaultGateway "10.10.0.1"
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses "10.10.0.10"  # DC IP

Rename-Computer -NewName "win11client" -Force
```

### 9-2. Domain Join

```powershell
$cred = [pscredential]::new(
    "PQCLAB\labadmin",
    (ConvertTo-SecureString "P@ssw0rd-PQCLab2026!" -AsPlainText -Force)
)
Add-Computer -DomainName "pqclab.local" -Credential $cred -Force -Restart
```

Wait 90 seconds for reboot. Log back in as `PQCLAB\labadmin`.

### 9-3. Enable ML-KEM Hybrid Groups

Apply the same commands from **Section 8** on the Win11 client:

```powershell
Enable-TlsEccCurve -Name "x25519_mlkem768"
Enable-TlsEccCurve -Name "secp256r1_mlkem768"
Enable-TlsEccCurve -Name "secp384r1_mlkem1024"

Set-TlsEccCurve -Name @(
    "x25519_mlkem768",
    "secp256r1_mlkem768",
    "secp384r1_mlkem1024",
    "NistP384",
    "NistP256",
    "x25519"
)

# Registry persistence (MultiString)
$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010003"
if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
Set-ItemProperty -Path $regBase -Name "Functions" -Value @(
    "x25519_mlkem768",
    "secp256r1_mlkem768",
    "secp384r1_mlkem1024",
    "NistP384",
    "NistP256",
    "x25519"
) -Type MultiString

# TLS 1.3 client
$clientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
if (-not (Test-Path $clientKey)) { New-Item -Path $clientKey -Force | Out-Null }
Set-ItemProperty -Path $clientKey -Name "Enabled"          -Value 1 -Type DWord
Set-ItemProperty -Path $clientKey -Name "DisabledByDefault" -Value 0 -Type DWord

# Schannel event logging
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL" `
    -Name "EventLogging" -Value 7 -Type DWord -Force

Restart-Computer -Force
```

Wait 90 seconds. Log back in as `PQCLAB\labadmin`.

### 9-4. Force Group Policy (Root CA Trust)

Domain Group Policy automatically distributes the Root CA certificate to all domain
members' Trusted Root store. Force an immediate update:

```powershell
gpupdate /force /wait:60
```

### 9-5. Verify Root CA Trust

```powershell
Get-ChildItem cert:\LocalMachine\Root |
    Where-Object { $_.Subject -match "PQCLab" } |
    Select-Object Subject, Thumbprint,
        @{n="SigAlg";  e={$_.SignatureAlgorithm.FriendlyName}},
        @{n="Expires"; e={$_.NotAfter.ToString("yyyy-MM-dd")}} |
    Format-List
```

**Expected:** One entry for `CN=PQCLab Root CA` with `SigAlg` showing `id-ML-DSA-87`.

---

## 10. End-to-End PQC TLS Verification

### 10-1. PowerShell TLS Handshake Test

**Run on:** `win11client`

```powershell
$target = "webserver01.pqclab.local"

$tcp = New-Object System.Net.Sockets.TcpClient($target, 443)
$ssl = New-Object System.Net.Security.SslStream(
    $tcp.GetStream(), $false,
    [System.Net.Security.RemoteCertificateValidationCallback]{ param($s,$c,$ch,$e) $true }
)
$ssl.AuthenticateAsClient($target)

Write-Host "TLS Protocol     : $($ssl.SslProtocol)"
Write-Host "Cipher Suite     : $($ssl.NegotiatedCipherSuite)"
Write-Host "Is Authenticated : $($ssl.IsAuthenticated)"
Write-Host "Is Encrypted     : $($ssl.IsEncrypted)"

$serverCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    $ssl.RemoteCertificate
)
Write-Host ""
Write-Host "Server Certificate:"
Write-Host "  Subject    : $($serverCert.Subject)"
Write-Host "  Issuer     : $($serverCert.Issuer)"
Write-Host "  Valid Until: $($serverCert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "  Sig Alg    : $($serverCert.SignatureAlgorithm.FriendlyName)"

$ssl.Close(); $tcp.Close()
```

**Expected output:**
```
TLS Protocol     : Tls13
Cipher Suite     : TLS_AES_256_GCM_SHA384
Is Authenticated : True
Is Encrypted     : True

Server Certificate:
  Subject    : CN=webserver01.pqclab.local
  Issuer     : CN=PQCLab Issuing CA
  Valid Until: 2027-xx-xx
  Sig Alg    : id-ML-DSA-65
```

> The **key exchange group** (`x25519_mlkem768`) is not exposed by `NegotiatedCipherSuite`
> in the .NET `SslStream` API. Use the Schannel event log or Edge DevTools to confirm it.

### 10-2. Schannel Event Log Check

```powershell
# Make an HTTPS request to generate a Schannel event
Invoke-WebRequest -Uri "https://webserver01.pqclab.local" -UseBasicParsing | Out-Null
Start-Sleep -Seconds 2

# Read Event ID 36880 (TLS Session Established — includes KEM group details)
Get-WinEvent -FilterHashtable @{
    LogName      = "System"
    ProviderName = "Schannel"
    Id           = 36880
    StartTime    = (Get-Date).AddMinutes(-5)
} | Select-Object -First 3 | ForEach-Object {
    Write-Host "[$($_.TimeCreated.ToString('HH:mm:ss'))] $($_.Message)"
    Write-Host "---"
}
```

Look for `x25519_mlkem768` in the event message text.

### 10-3. Browser Verification (Microsoft Edge)

1. Open **Microsoft Edge** on `win11client`.
2. Navigate to `https://webserver01.pqclab.local`.
3. **Certificate check:** Click the padlock → *Connection is secure* → *Certificate is valid*
   - Confirm: Subject = `CN=webserver01.pqclab.local`
   - Confirm: Issuer = `PQCLab Issuing CA`
   - Confirm: Signature algorithm = `id-ML-DSA-65`
4. **Key exchange check:** Press **F12** → **Security** tab → **Connection** section
   - Confirm: **Key exchange:** `x25519_mlkem768`
   - Confirm: **Protocol:** `TLS 1.3`

### 10-4. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Key exchange shows `ECDH P-256` or `x25519` (no mlkem suffix) | ML-KEM not enabled or restart missing | Re-run Section 8 on both server and client; restart both |
| Certificate error in browser | Root CA not in Trusted Root store | Run `gpupdate /force` on client; wait 2 min |
| `certreq -submit` fails | Issuing CA not reachable or template not published | Check `certsvc` on issuingca; confirm `Add-CATemplate` ran |
| `Install-AdcsCertificationAuthority` fails on ML-DSA | KB5099536 not installed | Install KB5099536 (build 26100.33158+) |
| `Enable-TlsEccCurve` cmdlet not found | Wrong OS version | Must be Win Server 2025 GA + KB5099536 or vNext 29550+ |

---

## 11. Expected End State Summary

After completing all steps, each machine should be in the following state:

### Root CA (`rootca`)
- `certsvc` installed and running
- CA type: StandaloneRootCA
- Key algorithm: `ML-DSA:87#Microsoft Software Key Storage Provider`
- CA is **offline** (shut down after issuing SubCA certificate)
- `C:\PKI-Export\RootCA.cer` and `RootCA.crl` exist

### Domain Controller (`dc01`)
- AD DS forest `pqclab.local` is promoted
- DNS server is running
- `svc-ca-enroll` user account exists in AD
- ML-KEM hybrid groups enabled (TLS 1.3 only; affects LDAPS)
- Services: `ADWS`, `DNS`, `Netlogon` all `Running`

### Issuing CA (`issuingca`)
- Domain member of `pqclab.local`
- `certsvc` running — Enterprise Subordinate CA `PQCLab Issuing CA`
- Key algorithm: `ML-DSA:65#Microsoft Software Key Storage Provider`
- SubCA certificate signed by Root CA and installed
- Template `PQCWebServer` published to CA
- Root CA published to AD (`certutil -dspublish`)

### Web Server (`webserver01`)
- Domain member of `pqclab.local`
- IIS installed; Default Web Site listening on HTTPS port 443
- TLS certificate: `CN=webserver01.pqclab.local`, signed by `PQCLab Issuing CA`, algorithm `id-ML-DSA-65`
- ML-KEM hybrid groups enabled; TLS 1.3 explicitly set; VM restarted after configuration

### Win11 Client (`win11client`)
- Domain member of `pqclab.local`
- OS: Windows 11 24H2 GA, build ≥ 26100.8524 (KB5101650 applied)
- ML-KEM hybrid groups enabled (`x25519_mlkem768` at highest priority)
- Root CA trusted (via GPO / Trusted Root store)
- `Get-WinEvent` EventID 36880 confirms `x25519_mlkem768` in last TLS session
- Edge DevTools F12 → Security tab shows `x25519_mlkem768` as key exchange

---

## 12. Comparison: Manual vs Scripted End State

| Configuration Item | Scripted Result | Manual Result | Notes |
|-------------------|----------------|---------------|-------|
| Root CA key algorithm | `ML-DSA:87#Microsoft Software Key Storage Provider` | Same | Identical parameters |
| Issuing CA key algorithm | `ML-DSA:65#Microsoft Software Key Storage Provider` | Same | Identical parameters |
| Template `pKIDefaultKeySpec` | 2 (AT_SIGNATURE) | Same | Critical — must be 2 for ML-DSA |
| TLS 1.3 registry | Both Server + Client keys set to Enabled=1 | Same | Hyper-V script uses `New-ItemProperty`; Azure uses `Set-ItemProperty` |
| KEM group registry type | `REG_MULTI_SZ` (both paths) | `REG_MULTI_SZ` | Both deployment scripts now use `MultiString`; manual guide matches |
| CRL period | 1 week (Root CA) | Same | Shortened for test lab |
| IIS binding | `0.0.0.0!443` | Same | No SNI host header limitation |
| Schannel EventLogging | Level 7 (Win11 client only) | Same | Enables Event ID 36880 |
| Domain account | `PQCLAB\labadmin` | Same | |
| Hostname | `rootca`, `dc01`, `issuingca`, `webserver01`, `win11client` | Same | Hostnames are set by scripts via `Rename-Computer` |

> **Note:** All scripts use `REG_MULTI_SZ` (`-Type MultiString`) for the `Functions`
> registry key, which is the documented format for `SSL\00010003\Functions`. The manual
> guide uses the same type, so scripted and manual builds produce identical registry state.
