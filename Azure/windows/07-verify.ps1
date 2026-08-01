# =============================================================================
# PQC PKI Lab — Phase 8+9: Trust Distribution + Verification
# Distributes Root CA trust via GPO and verifies the full PQC chain
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# =============================================================================
# Step 1: Push Root CA trust to all domain members via GPO
# =============================================================================
Write-Host "=== Step 1: Deploy Root CA trust via GPO ===" -ForegroundColor Cyan

$gpoScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[Trust `$(Get-Date -Format HH:mm:ss)] `$msg" }

Import-Module GroupPolicy

# Create a GPO for Root CA trust
`$gpoName = "PQCLab-RootCA-Trust"
`$gpo = New-GPO -Name `$gpoName -Comment "Distributes PQCLab Root CA to Trusted Root store"

# Get the Root CA certificate bytes
`$rootCaCert = Get-ChildItem "cert:\LocalMachine\Root" | Where-Object {`$_.Subject -match "PQCLab Root CA"} | Select-Object -First 1

if (-not `$rootCaCert) {
    Write-Warning "Root CA cert not found in local store. Importing from file..."
    certutil -addstore Root "C:\PKI-Import\RootCA.cer"
    `$rootCaCert = Get-ChildItem "cert:\LocalMachine\Root" | Where-Object {`$_.Subject -match "PQCLab Root CA"} | Select-Object -First 1
}

# Export the cert to a temp path for GPO import
`$certPath = "C:\temp\RootCA-GPO.cer"
New-Item -ItemType Directory -Force -Path "C:\temp" | Out-Null
[System.IO.File]::WriteAllBytes(`$certPath, `$rootCaCert.RawData)

Log "Root CA cert exported for GPO import: `$certPath"

# Import into GPO's Trusted Root CA setting
# Use certutil to publish to NTAuth and Root stores in AD
certutil -dspublish -f "`$certPath" RootCA
certutil -dspublish -f "`$certPath" NTAuthCA

# Link GPO to domain
`$domain = Get-ADDomain
`$domainDN = `$domain.DistinguishedName
New-GPLink -Name `$gpoName -Target `$domainDN -Enforced Yes

# Force GP update
gpupdate /force

Log "Root CA trust GPO created and linked to domain."
Log "All domain members will receive the Root CA in their Trusted Root store on next GP refresh."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_DC `
    --command-id RunPowerShellScript `
    --scripts $gpoScript

# =============================================================================
# Step 2: Verification — check the full PKI chain
# =============================================================================
Write-Host "=== Step 2: Verify PKI chain on Issuing CA ===" -ForegroundColor Cyan

$verifyScript = @"
function Log([string]`$msg) { Write-Host "[Verify `$(Get-Date -Format HH:mm:ss)] `$msg" }

Log "--- Root CA Certificate ---"
Get-ChildItem "cert:\LocalMachine\Root" | Where-Object {`$_.Subject -match "PQCLab"} |
    Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint, @{n="Algorithm";e={`$_.SignatureAlgorithm.FriendlyName}} |
    Format-List

Log "--- Issuing CA Certificate ---"
Get-ChildItem "cert:\LocalMachine\CA" | Where-Object {`$_.Subject -match "PQCLab"} |
    Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint, @{n="Algorithm";e={`$_.SignatureAlgorithm.FriendlyName}} |
    Format-List

Log "--- CA Service Status ---"
Get-Service certsvc | Select-Object Name, Status, StartType

Log "--- certutil ping ---"
certutil -ping

Log "--- Published Templates ---"
certutil -catemplates
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $verifyScript

# =============================================================================
# Step 3: Verify TLS certificate on Web Server
# =============================================================================
Write-Host "=== Step 3: Verify TLS on Web Server ===" -ForegroundColor Cyan

$tlsVerifyScript = @"
function Log([string]`$msg) { Write-Host "[Verify `$(Get-Date -Format HH:mm:ss)] `$msg" }

# Check IIS certificate binding
Log "--- IIS Certificate Binding ---"
Get-WebBinding -Name "Default Web Site" | Where-Object {`$_.protocol -eq "https"} | Format-List

# Check the bound certificate
`$binding = Get-WebBinding -Name "Default Web Site" -Protocol https
if (`$binding) {
    `$certThumb = (`$binding.certificateHash)
    `$cert = Get-ChildItem "cert:\LocalMachine\My\`$certThumb" -ErrorAction SilentlyContinue
    if (`$cert) {
        Log "--- TLS Certificate Details ---"
        `$cert | Select-Object Subject, Issuer, NotAfter, Thumbprint, @{n="SigAlg";e={`$_.SignatureAlgorithm.FriendlyName}} | Format-List
    }
}

# Quick TLS test from localhost
Log "--- Testing HTTPS localhost ---"
try {
    `$response = Invoke-WebRequest -Uri "https://localhost" -SkipCertificateCheck -TimeoutSec 10
    Write-Host "HTTPS response: `$(`$response.StatusCode) `$(`$response.StatusDescription)"
} catch {
    Write-Warning "HTTPS test: `$(`$_.Exception.Message)"
}

# Show enabled KEM groups
Log "--- TLS KEM/ECC Groups ---"
Get-TlsEccCurve | Format-Table Name, Priority -AutoSize
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_WEBSERVER `
    --command-id RunPowerShellScript `
    --scripts $tlsVerifyScript

# =============================================================================
# Step 4: Print connection details for browser testing
# =============================================================================
Write-Host ""
Write-Host "=== LAB DEPLOYMENT COMPLETE ===" -ForegroundColor Green
Write-Host ""
Write-Host "VM Summary:" -ForegroundColor Cyan

$vmNames = @($VM_ROOTCA, $VM_DC, $VM_ISSUINGCA, $VM_WEBSERVER)
foreach ($vmName in $vmNames) {
    $pip = az network public-ip show `
        --resource-group $RESOURCE_GROUP `
        --name "$vmName-pip" `
        --query "ipAddress" -o tsv
    Write-Host "  $($vmName.PadRight(30)) Public IP: $pip"
}

Write-Host ""
Write-Host "Testing instructions:" -ForegroundColor Cyan
Write-Host "  1. RDP to webserver ($VM_WEBSERVER) public IP"
Write-Host "  2. Open Edge browser: https://webserver01.$DOMAIN_NAME"
Write-Host "  3. Check certificate: lock icon → Connection is secure → Certificate valid"
Write-Host "  4. Expected: ML-DSA-65 signature, x25519_mlkem768 key exchange, TLS 1.3"
Write-Host "  5. For TLS inspection: open Edge DevTools → Security tab"
Write-Host ""
Write-Host "OR use PowerShell from any domain-joined VM:"
Write-Host "  Test-NetConnection -ComputerName webserver01.$DOMAIN_NAME -Port 443"
Write-Host "  [System.Net.ServicePointManager]::SecurityProtocol"
Write-Host ""
Write-Host "Shutdown Root CA when not in use:" -ForegroundColor Yellow
Write-Host "  az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_ROOTCA"
