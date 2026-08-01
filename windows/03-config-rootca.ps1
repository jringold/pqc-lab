# =============================================================================
# PQC PKI Lab — Phase 3: Configure Standalone Root CA (ML-DSA-87)
# Runs inside the Root CA VM via Azure VM Run Command.
#
# The Root CA is STANDALONE (not domain-joined). After signing the Sub-CA
# certificate, this VM should be shut down and kept offline.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

$innerScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[RootCA `$(Get-Date -Format HH:mm:ss)] `$msg" }

# --- 1. Set hostname ---
Log "Setting hostname to rootca..."
Rename-Computer -NewName "rootca" -Force -ErrorAction SilentlyContinue

# --- 2. Install AD CS role (management tools only needed for standalone) ---
Log "Installing ADCS-Cert-Authority role..."
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools -Confirm:`$false

# --- 3. Configure Standalone Root CA with ML-DSA-87 ---
# ML-DSA-87 key length in bits: 2592 bytes x 8 = 20736
# HashAlgorithm MUST be NoHash (ML-DSA handles hashing internally)
Log "Configuring Standalone Root CA with ML-DSA-87..."

Install-AdcsCertificationAuthority ``
    -CAType StandaloneRootCA ``
    -CACommonName "PQCLab Root CA" ``
    -KeyLength 20736 ``
    -HashAlgorithm NoHash ``
    -CryptoProviderName "ML-DSA:87#Microsoft Software Key Storage Provider" ``
    -ValidityPeriod Years ``
    -ValidityPeriodUnits 10 ``
    -Force

Log "Root CA installed."

# --- 4. Configure CRL and AIA extensions ---
# Shorten CRL lifetime for a test lab (default is too long)
Log "Configuring CRL settings..."
certutil -setreg CA\CRLPeriodUnits 1
certutil -setreg CA\CRLPeriod "Weeks"
certutil -setreg CA\CRLDeltaPeriodUnits 0
certutil -setreg CA\CRLDeltaPeriod "Days"
certutil -setreg CA\ValidityPeriodUnits 5

Restart-Service certsvc
Start-Sleep 5

# --- 5. Publish initial CRL ---
Log "Publishing CRL..."
certutil -crl

# --- 6. Export Root CA certificate ---
Log "Exporting Root CA certificate..."
`$outDir = "C:\PKI-Export"
New-Item -ItemType Directory -Force -Path `$outDir | Out-Null

certutil -ca.cert "`$outDir\RootCA.cer"

# Export CRL
`$crl = Get-ChildItem "C:\Windows\system32\CertSrv\CertEnroll" -Filter "*.crl" | Select-Object -First 1
if (`$crl) { Copy-Item `$crl.FullName "`$outDir\RootCA.crl" }

# --- 7. Verify ---
Log "Verifying Root CA certificate..."
certutil -store Root "PQCLab Root CA"

Log "=== ROOT CA SETUP COMPLETE ==="
Log "Certificate exported to: `$outDir\RootCA.cer"
Log "CRL exported to: `$outDir\RootCA.crl"
Log "NEXT: Copy RootCA.cer and RootCA.crl to the Issuing CA VM at C:\PKI-Import\"
"@

Write-Host "=== Deploying Root CA configuration ===" -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ROOTCA `
    --command-id RunPowerShellScript `
    --scripts $innerScript

Write-Host ""
Write-Host "=== Root CA configured ===" -ForegroundColor Green
Write-Host ""
Write-Host "ACTION REQUIRED: Copy files from Root CA to Issuing CA"
Write-Host "  From: $VM_ROOTCA  C:\PKI-Export\RootCA.cer"
Write-Host "  From: $VM_ROOTCA  C:\PKI-Export\RootCA.crl"
Write-Host "  To  : $VM_ISSUINGCA  C:\PKI-Import\"
Write-Host ""
Write-Host "You can do this transfer via:"
Write-Host "  1. RDP to Root CA, copy files, RDP to Issuing CA, paste"
Write-Host "  2. Use the 03b-copy-certs-between-vms.ps1 script (uses Azure Blob as relay)"
Write-Host ""
Write-Host "Next step: run 03b-copy-certs-between-vms.ps1, then 04-config-issuingca.ps1"
