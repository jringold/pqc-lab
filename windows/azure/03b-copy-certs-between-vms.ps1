# =============================================================================
# PQC PKI Lab — Phase 3b: Transfer PKI files between VMs via Azure Blob
# 
# Because the Root CA and Issuing CA are on different VMs (and the Root CA
# is NOT domain-joined), files are relayed through Azure Blob Storage.
#
# Files moved:
#   Root CA   → Blob  : RootCA.cer, RootCA.crl
#   Blob      → IssCA : RootCA.cer, RootCA.crl
#   IssCA     → Blob  : SubCA.req  (after Sub-CA request is generated)
#   Blob      → RootCA: SubCA.req  (for signing)
#   RootCA    → Blob  : SubCA.cer  (signed certificate)
#   Blob      → IssCA : SubCA.cer  (install on Issuing CA)
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# Generate a SAS token valid for 2 hours
$sasExpiry = (Get-Date).AddHours(2).ToUniversalTime().ToString("yyyy-MM-ddTHH:mmZ")
$sasToken  = az storage container generate-sas `
    --name $STORAGE_CONTAINER `
    --account-name $STORAGE_ACCOUNT `
    --permissions racwdl `
    --expiry $sasExpiry `
    --auth-mode login `
    --output tsv

$blobBase  = "https://$STORAGE_ACCOUNT.blob.core.windows.net/$STORAGE_CONTAINER"
$uploadUrl = "$blobBase/RootCA.cer`?$sasToken"
$crlUrl    = "$blobBase/RootCA.crl`?$sasToken"
$subReqUrl = "$blobBase/SubCA.req`?$sasToken"
$subCerUrl = "$blobBase/SubCA.cer`?$sasToken"

# =============================================================================
# Step 1: Root CA → upload RootCA.cer + RootCA.crl to blob
# =============================================================================
Write-Host "=== Step 1: Upload Root CA cert + CRL to blob ===" -ForegroundColor Cyan

$uploadScript = @"
`$blobBase = "$blobBase"
`$sasToken = "$sasToken"

function Upload-ToBlobSas([string]`$localFile, [string]`$blobUrl) {
    `$bytes = [System.IO.File]::ReadAllBytes(`$localFile)
    Invoke-RestMethod -Uri `$blobUrl -Method Put ``
        -Headers @{"x-ms-blob-type"="BlockBlob"} ``
        -Body `$bytes -ContentType "application/octet-stream"
}

Upload-ToBlobSas "C:\PKI-Export\RootCA.cer" "$uploadUrl"
Upload-ToBlobSas "C:\PKI-Export\RootCA.crl" "$crlUrl"
Write-Host "RootCA.cer and RootCA.crl uploaded."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ROOTCA `
    --command-id RunPowerShellScript `
    --scripts $uploadScript

# =============================================================================
# Step 2: Issuing CA ← download RootCA.cer + RootCA.crl from blob
# =============================================================================
Write-Host "=== Step 2: Download Root CA files to Issuing CA ===" -ForegroundColor Cyan

$downloadScript = @"
New-Item -ItemType Directory -Force -Path "C:\PKI-Import" | Out-Null

function Download-FromBlobSas([string]`$blobUrl, [string]`$localFile) {
    `$bytes = (Invoke-WebRequest -Uri `$blobUrl -UseBasicParsing).Content
    [System.IO.File]::WriteAllBytes(`$localFile, `$bytes)
}

Download-FromBlobSas "$uploadUrl" "C:\PKI-Import\RootCA.cer"
Download-FromBlobSas "$crlUrl"    "C:\PKI-Import\RootCA.crl"
Write-Host "Downloaded: C:\PKI-Import\RootCA.cer"
Write-Host "Downloaded: C:\PKI-Import\RootCA.crl"
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_ISSUINGCA `
    --command-id RunPowerShellScript `
    --scripts $downloadScript

Write-Host "Root CA files transferred to Issuing CA." -ForegroundColor Green
Write-Host "Next step: run 04-config-issuingca.ps1"
