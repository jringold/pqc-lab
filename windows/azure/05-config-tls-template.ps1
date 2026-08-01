# =============================================================================
# PQC PKI Lab — Phase 5+6: Create TLS Certificate Template and Enroll
# Creates the "PQC Web Server" template and enrolls the Web Server VM
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# =============================================================================
# Step 1: Create the PQC TLS certificate template on the Issuing CA
# =============================================================================
Write-Host "=== Step 1: Create PQC Web Server certificate template ===" -ForegroundColor Cyan

$templateScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[Template `$(Get-Date -Format HH:mm:ss)] `$msg" }

Import-Module ActiveDirectory

Log "Duplicating Web Server template to create PQC Web Server..."

# Load ADSI LDAP connection to Certificate Templates
`$configContext = (Get-ADRootDSE).configurationNamingContext
`$templateContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,`$configContext"

# Get the built-in Web Server template as the source
`$webServerTemplate = [ADSI]"LDAP://CN=WebServer,`$templateContainer"

# Create the new template object by copying
`$newTemplate = `$webServerTemplate.psbase.CopyTo("LDAP://CN=PQCWebServer,`$templateContainer")
`$newTemplate.Put("cn", "PQCWebServer")
`$newTemplate.Put("displayName", "PQC Web Server")

# Set the flags:
# msPKI-Certificate-Name-Flag = 1 (Subject from request)
`$newTemplate.Put("msPKI-Certificate-Name-Flag", 1)

# pKIDefaultKeySpec = 2 = AT_SIGNATURE (Signature only — required for ML-DSA)
`$newTemplate.Put("pKIDefaultKeySpec", 2)

# Set cryptography settings: ML-DSA:65, KSP
`$newTemplate.Put("pKIDefaultCSPs", @("1,ML-DSA:65#Microsoft Software Key Storage Provider"))

# Minimum key size (ML-DSA-65 public key = 1952 bytes = 15616 bits)
`$newTemplate.Put("msPKI-Minimal-Key-Size", 15616)

# Set validity to 1 year
`$newTemplate.Put("pKIExpirationPeriod", [byte[]](0,64,57,135,46,225,254,255))   # ~1 year in 100ns intervals
`$newTemplate.Put("pKIOverlapPeriod",    [byte[]](0,128,166,10,255,222,255,255)) # ~6 week renewal window

# Application policies: Server Authentication OID only
# Remove EFS and Secure Email EKUs — leave only 1.3.6.1.5.5.7.3.1 (serverAuth)
`$newTemplate.Put("pKIExtendedKeyUsage", @("1.3.6.1.5.5.7.3.1"))

# Request handling: set Purpose to Signature (value = 2)
# This is the CRITICAL field — ML-DSA is signature-only
`$newTemplate.Put("msPKI-Private-Key-Flag", 0x00000110)  # Exportable=off, purpose=signature

`$newTemplate.SetInfo()
Log "Template object created in AD."

# Grant Enroll permission to Domain Computers
`$domainComputersSid = (Get-ADGroup "Domain Computers").SID
`$acl = `$newTemplate.psbase.ObjectSecurity
`$accessRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    `$domainComputersSid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"  # Certificate-Enrollment right
)
`$acl.AddAccessRule(`$accessRule)
`$newTemplate.psbase.CommitChanges()
Log "Enrollment permission granted to Domain Computers."

# Publish the template to the Issuing CA
Log "Publishing template to CA..."
Add-CATemplate -Name "PQCWebServer" -Force

Log "=== Certificate template 'PQC Web Server' ready ==="
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $templateScript

# =============================================================================
# Step 2: Join Web Server to the domain
# =============================================================================
Write-Host "=== Step 2: Join Web Server to domain ===" -ForegroundColor Cyan

$joinScript = @"
`$cred = New-Object System.Management.Automation.PSCredential(
    "$DOMAIN_NETBIOS\$ADMIN_USER",
    (ConvertTo-SecureString "$ADMIN_PASS" -AsPlainText -Force)
)
Rename-Computer -NewName "webserver01" -Force -ErrorAction SilentlyContinue
Add-Computer -DomainName "$DOMAIN_NAME" -Credential `$cred -Force -Restart
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_WEBSERVER `
    --command-id RunPowerShellScript `
    --scripts $joinScript

Write-Host "Web server joining domain — waiting 2 minutes for reboot..."
Start-Sleep -Seconds 120

# =============================================================================
# Step 3: Install IIS and enroll PQC TLS certificate
# =============================================================================
Write-Host "=== Step 3: Install IIS + enroll PQC TLS certificate ===" -ForegroundColor Cyan

$iisScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[WebServer `$(Get-Date -Format HH:mm:ss)] `$msg" }

# Install IIS
Log "Installing IIS..."
Install-WindowsFeature Web-Server, Web-Mgmt-Console -Confirm:`$false

# Wait for AD CS enrollment to be ready
Log "Waiting for CA enrollment service..."
Start-Sleep -Seconds 30

# Request PQC TLS certificate from the Issuing CA
Log "Enrolling PQC Web Server certificate..."
`$hostname    = "`$env:COMPUTERNAME.$DOMAIN_NAME"
`$certStore   = "cert:\LocalMachine\My"

# Use certreq via INF file for fine-grained control
`$inf = @"
[Version]
Signature = "\$Windows NT\$"

[NewRequest]
Subject     = "CN=`$hostname"
KeyAlgorithm = ML-DSA
KeyLength    = 15616
HashAlgorithm = NoHash
MachineKeySet = True
RequestType = PKCS10
KeySpec = 2
ProviderName = "ML-DSA:65#Microsoft Software Key Storage Provider"
ProviderType = 0
SMIME = FALSE
Silent = TRUE

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1 ; Server Authentication

[RequestAttributes]
CertificateTemplate = PQCWebServer

[Extensions]
2.5.29.17 = "{text}dns=`$hostname&dns=webserver01"
"@

`$inf | Out-File -FilePath "C:\temp\pqc-tls.inf" -Encoding ascii -Force
New-Item -ItemType Directory -Force -Path "C:\temp" | Out-Null

certreq -new "C:\temp\pqc-tls.inf" "C:\temp\pqc-tls.req"
certreq -submit -config "$VM_ISSUINGCA.$DOMAIN_NAME\PQCLab Issuing CA" "C:\temp\pqc-tls.req" "C:\temp\pqc-tls.cer"
certreq -accept "C:\temp\pqc-tls.cer"

# Bind the certificate to IIS HTTPS
Log "Binding certificate to IIS on port 443..."
`$cert   = Get-ChildItem `$certStore | Where-Object {`$_.Subject -match "`$env:COMPUTERNAME"} | Select-Object -First 1
`$thumb  = `$cert.Thumbprint

Import-Module WebAdministration
Remove-WebBinding -Name "Default Web Site" -Protocol https -ErrorAction SilentlyContinue
New-WebBinding -Name "Default Web Site" -Protocol https -Port 443 -HostHeader `$hostname

`$sslPath = "IIS:\SslBindings\0.0.0.0!443"
if (Test-Path `$sslPath) { Remove-Item `$sslPath -Force }
Get-Item "cert:\LocalMachine\My\`$thumb" | New-Item `$sslPath

Log "IIS HTTPS binding set with PQC certificate (thumbprint: `$thumb)"
Log "=== WEB SERVER SETUP COMPLETE ==="
Log "Test URL: https://`$hostname"
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_WEBSERVER `
    --command-id RunPowerShellScript `
    --scripts $iisScript

Write-Host ""
Write-Host "=== TLS Template + IIS certificate enrollment complete ===" -ForegroundColor Green
Write-Host "Next step: run 06-enable-mlkem-tls.ps1"
