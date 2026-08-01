# =============================================================================
# PQC PKI Lab — Phase 4: Configure Enterprise Issuing CA (ML-DSA-65)
# Must run AFTER:
#   - DC is promoted (02-config-dc.ps1)
#   - Root CA is set up (03-config-rootca.ps1)
#   - Root CA certs transferred to Issuing CA (03b-copy-certs-between-vms.ps1)
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# Generate SAS for SubCA.req transfer back to Root CA
$sasExpiry = (Get-Date).AddHours(4).ToUniversalTime().ToString("yyyy-MM-ddTHH:mmZ")
$sasToken  = az storage container generate-sas `
    --name $STORAGE_CONTAINER `
    --account-name $STORAGE_ACCOUNT `
    --permissions racwdl `
    --expiry $sasExpiry `
    --auth-mode login `
    --output tsv

$blobBase  = "https://$STORAGE_ACCOUNT.blob.core.windows.net/$STORAGE_CONTAINER"

# =============================================================================
# Step 1: Join Issuing CA to the domain
# =============================================================================
Write-Host "=== Step 1: Join Issuing CA to domain $DOMAIN_NAME ===" -ForegroundColor Cyan

$joinScript = @"
`$cred = New-Object System.Management.Automation.PSCredential(
    "$DOMAIN_NETBIOS\$ADMIN_USER",
    (ConvertTo-SecureString "$ADMIN_PASS" -AsPlainText -Force)
)
Add-Computer -DomainName "$DOMAIN_NAME" -Credential `$cred -Force -Restart
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $joinScript

Write-Host "Issuing CA joining domain — waiting 2 minutes for reboot..."
Start-Sleep -Seconds 120

# =============================================================================
# Step 2: Install and configure Enterprise Subordinate CA (ML-DSA-65)
# =============================================================================
Write-Host "=== Step 2: Configure Enterprise Issuing CA ===" -ForegroundColor Cyan

$issuingCaScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[IssuingCA `$(Get-Date -Format HH:mm:ss)] `$msg" }

# Install AD CS role
Log "Installing ADCS-Cert-Authority role..."
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools -Confirm:`$false

# Import Root CA trust before installing sub-CA
Log "Importing Root CA into local store..."
certutil -addstore Root "C:\PKI-Import\RootCA.cer"
certutil -addstore -enterprise Root "C:\PKI-Import\RootCA.cer"

# Publish CRL from Root CA
certutil -addstore Root "C:\PKI-Import\RootCA.crl"
certutil -setreg CA\CRLPublicationURLs "65:C:\Windows\system32\CertSrv\CertEnroll\%3%8.crl\n3:http://pki.$DOMAIN_NAME/pki/%3%8.crl"

# ML-DSA-65: 1952 bytes x 8 = 15616 bits
Log "Installing Enterprise Subordinate CA with ML-DSA-65..."

Install-AdcsCertificationAuthority ``
    -CAType EnterpriseSubordinateCA ``
    -CACommonName "PQCLab Issuing CA" ``
    -KeyLength 15616 ``
    -HashAlgorithm NoHash ``
    -CryptoProviderName "ML-DSA:65#Microsoft Software Key Storage Provider" ``
    -OutputCertRequestFile "C:\PKI-Export\SubCA.req" ``
    -Force

Log "SubCA CSR generated: C:\PKI-Export\SubCA.req"
Log "This CA will remain in a 'pending' state until the Root CA signs the certificate."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $issuingCaScript

# =============================================================================
# Step 3: Upload SubCA.req to blob for Root CA to sign
# =============================================================================
Write-Host "=== Step 3: Upload SubCA.req to blob ===" -ForegroundColor Cyan

$subReqUrl = "$blobBase/SubCA.req`?$sasToken"

$uploadReqScript = @"
function Upload-ToBlobSas([string]`$localFile, [string]`$blobUrl) {
    `$bytes = [System.IO.File]::ReadAllBytes(`$localFile)
    Invoke-RestMethod -Uri `$blobUrl -Method Put ``
        -Headers @{"x-ms-blob-type"="BlockBlob"} ``
        -Body `$bytes -ContentType "application/octet-stream"
}
Upload-ToBlobSas "C:\PKI-Export\SubCA.req" "$subReqUrl"
Write-Host "SubCA.req uploaded to blob."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $uploadReqScript

# =============================================================================
# Step 4: Root CA downloads and signs the SubCA.req
# =============================================================================
Write-Host "=== Step 4: Root CA signs SubCA.req ===" -ForegroundColor Cyan

$subCerUrl = "$blobBase/SubCA.cer`?$sasToken"

$signScript = @"
New-Item -ItemType Directory -Force -Path "C:\PKI-Import" | Out-Null

# Download SubCA.req from blob
`$bytes = (Invoke-WebRequest -Uri "$subReqUrl" -UseBasicParsing).Content
[System.IO.File]::WriteAllBytes("C:\PKI-Import\SubCA.req", `$bytes)
Write-Host "Downloaded SubCA.req"

# Submit to Root CA
`$reqId = certutil -submit "C:\PKI-Import\SubCA.req" | Select-String "RequestId" | ForEach-Object { (`$_ -split ":")[1].Trim().Split(" ")[0] }
Write-Host "Request ID: `$reqId"

# Issue the certificate (approve pending request)
certutil -resubmit `$reqId

# Retrieve signed cert
certutil -retrieve `$reqId "C:\PKI-Export\SubCA.cer"

# Upload signed cert to blob
function Upload-ToBlobSas([string]`$localFile, [string]`$blobUrl) {
    `$bytes = [System.IO.File]::ReadAllBytes(`$localFile)
    Invoke-RestMethod -Uri `$blobUrl -Method Put ``
        -Headers @{"x-ms-blob-type"="BlockBlob"} ``
        -Body `$bytes -ContentType "application/octet-stream"
}
Upload-ToBlobSas "C:\PKI-Export\SubCA.cer" "$subCerUrl"
Write-Host "SubCA.cer signed and uploaded."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ROOTCA `
    --command-id RunPowerShellScript `
    --scripts $signScript

# =============================================================================
# Step 5: Issuing CA installs the signed certificate and starts CA service
# =============================================================================
Write-Host "=== Step 5: Issuing CA installs signed certificate ===" -ForegroundColor Cyan

$installCerScript = @"
# Download signed SubCA.cer
`$bytes = (Invoke-WebRequest -Uri "$subCerUrl" -UseBasicParsing).Content
[System.IO.File]::WriteAllBytes("C:\PKI-Import\SubCA.cer", `$bytes)
Write-Host "Downloaded SubCA.cer"

# Install the certificate to complete CA setup
certreq -accept "C:\PKI-Import\SubCA.cer"

# Publish Root CA cert into AD
certutil -dspublish -f "C:\PKI-Import\RootCA.cer" RootCA

# Start the CA service
Start-Service certsvc
Start-Sleep -Seconds 5

`$svc = Get-Service certsvc
Write-Host "certsvc status: `$(`$svc.Status)"
certutil -ping

Write-Host "=== ISSUING CA ONLINE AND OPERATIONAL ==="
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $installCerScript

Write-Host ""
Write-Host "=== Issuing CA configuration complete ===" -ForegroundColor Green
Write-Host "Next step: run 05-config-tls-template.ps1"
