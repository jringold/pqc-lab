# =============================================================================
# PQC PKI Lab — Phase 0: Prepare Windows Server vNext Custom Azure Image
# Run this script on a LOCAL Hyper-V host (NOT in Azure) that has the
# Windows Server vNext Insider Preview ISO downloaded.
#
# Prerequisites:
#   - Hyper-V role installed on the local machine
#   - Windows Server vNext Preview ISO downloaded from:
#     https://aka.ms/DownloadWindowsServerPreviews
#   - Azure CLI installed and logged in: az login
#   - AzCopy installed: https://aka.ms/downloadazcopy
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"

# --- Step 1: Create a Hyper-V VM from the ISO and install Windows Server ----
# (Manual step — automated install requires an answer file)
Write-Host @"
=== MANUAL STEP REQUIRED ===
1. In Hyper-V Manager, create a Generation 2 VM:
   - Disk: Fixed VHD, 128 GB minimum
   - RAM: 4 GB minimum
   - Network: any internal/external switch
2. Attach the vNext ISO as the boot DVD
3. Install Windows Server vNext (Datacenter or Standard)
4. Install all Windows Updates and reboot until clean
5. Run the Sysprep generalization below AFTER setup is complete

Press Enter when the VM is fully set up and you are ready to generalize...
"@
Read-Host

# --- Step 2: Generalize the VM (run INSIDE the Hyper-V VM) ------------------
Write-Host "Run this block INSIDE the Hyper-V guest VM before shutting it down:"
Write-Host @'
# --- Run inside the vNext VM ---
# Uninstall VM-specific extensions / cleanup
Get-AppxPackage -AllUsers | Where-Object {$_.NonRemovable -eq $false} | Remove-AppxPackage -ErrorAction SilentlyContinue

# Generalize with Sysprep
$sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
& $sysprep /generalize /oobe /shutdown /quiet
# The VM will shut down automatically when Sysprep completes.
'@

Read-Host "Press Enter once the VM has shut down after Sysprep..."

# --- Step 3: Convert VHDX → fixed VHD (if needed) ---------------------------
$vhdxPath = Read-Host "Enter the full path to the VM's .vhdx (or .vhd) disk file"
$vhdPath  = [IO.Path]::ChangeExtension($vhdxPath, ".vhd")

if ($vhdxPath -match "\.vhdx$") {
    Write-Host "Converting VHDX to fixed VHD..."
    Convert-VHD -Path $vhdxPath -DestinationPath $vhdPath -VHDType Fixed
    Write-Host "Conversion complete: $vhdPath"
} else {
    Write-Host "Already a .vhd — checking if it is fixed size..."
    $info = Get-VHD -Path $vhdxPath
    if ($info.VHDType -ne "Fixed") {
        Convert-VHD -Path $vhdxPath -DestinationPath $vhdPath -VHDType Fixed
        Write-Host "Converted to fixed VHD: $vhdPath"
    } else {
        $vhdPath = $vhdxPath
        Write-Host "VHD is already fixed — no conversion needed."
    }
}

# --- Step 4: Create Azure infrastructure for image upload --------------------
Write-Host "Logging in to Azure and setting subscription..."
az login --output none
az account set --subscription $SUBSCRIPTION_ID

Write-Host "Creating resource group: $RESOURCE_GROUP..."
az group create --name $RESOURCE_GROUP --location $LOCATION --tags @($TAGS.GetEnumerator() | ForEach-Object {"$($_.Key)=$($_.Value)"}) --output none

Write-Host "Creating storage account for VHD upload: $STORAGE_ACCOUNT..."
az storage account create `
    --name $STORAGE_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION `
    --sku Standard_LRS `
    --kind StorageV2 `
    --output none

$STORAGE_KEY = az storage account keys list `
    --account-name $STORAGE_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --query "[0].value" -o tsv

az storage container create `
    --name "vhds" `
    --account-name $STORAGE_ACCOUNT `
    --account-key $STORAGE_KEY `
    --output none

# --- Step 5: Upload VHD to Azure using AzCopy --------------------------------
$sasToken = az storage container generate-sas `
    --name "vhds" `
    --account-name $STORAGE_ACCOUNT `
    --account-key $STORAGE_KEY `
    --permissions rwl `
    --expiry ((Get-Date).AddHours(12).ToString("yyyy-MM-ddTHH:mmZ")) `
    --output tsv

$vhdBlobName = [IO.Path]::GetFileName($vhdPath)
$uploadUrl   = "https://$STORAGE_ACCOUNT.blob.core.windows.net/vhds/$vhdBlobName`?$sasToken"

Write-Host "Uploading VHD to Azure (this may take 30-60 minutes for a 128GB disk)..."
azcopy copy $vhdPath $uploadUrl --blob-type PageBlob

# --- Step 6: Create managed disk from VHD ------------------------------------
$diskName = "$PREFIX-vnext-os-disk"
Write-Host "Creating managed disk from uploaded VHD..."
az disk create `
    --resource-group $RESOURCE_GROUP `
    --name $diskName `
    --location $LOCATION `
    --source "https://$STORAGE_ACCOUNT.blob.core.windows.net/vhds/$vhdBlobName" `
    --hyper-v-generation V2 `
    --os-type Windows `
    --output none

# --- Step 7: Create Azure Compute Gallery + image definition ----------------
Write-Host "Creating Azure Compute Gallery: $IMAGE_GALLERY_NAME..."
az sig create `
    --resource-group $RESOURCE_GROUP `
    --gallery-name $IMAGE_GALLERY_NAME `
    --location $LOCATION `
    --output none

Write-Host "Creating image definition: $IMAGE_DEF_NAME..."
az sig image-definition create `
    --resource-group $RESOURCE_GROUP `
    --gallery-name $IMAGE_GALLERY_NAME `
    --gallery-image-definition $IMAGE_DEF_NAME `
    --publisher "WindowsInsider" `
    --offer "WindowsServerVNext" `
    --sku "Preview" `
    --os-type Windows `
    --os-state Generalized `
    --hyper-v-generation V2 `
    --output none

# Get the managed disk resource ID
$diskId = az disk show `
    --resource-group $RESOURCE_GROUP `
    --name $diskName `
    --query "id" -o tsv

Write-Host "Creating image version: $IMAGE_VERSION (this takes 10-20 minutes)..."
az sig image-version create `
    --resource-group $RESOURCE_GROUP `
    --gallery-name $IMAGE_GALLERY_NAME `
    --gallery-image-definition $IMAGE_DEF_NAME `
    --gallery-image-version $IMAGE_VERSION `
    --os-snapshot $diskId `
    --replica-count 1 `
    --target-regions $LOCATION `
    --output none

Write-Host ""
Write-Host "=== Image ready! ===" -ForegroundColor Green
Write-Host "Gallery : $IMAGE_GALLERY_NAME"
Write-Host "Image   : $IMAGE_DEF_NAME"
Write-Host "Version : $IMAGE_VERSION"
Write-Host ""
Write-Host "Proceed to 01-deploy-infrastructure.ps1"
