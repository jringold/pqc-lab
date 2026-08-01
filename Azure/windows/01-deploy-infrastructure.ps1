# =============================================================================
# PQC PKI Lab — Phase 1: Deploy Azure Infrastructure
# Creates: VNet, NSG, Bastion (optional), Storage for scripts, and 4 VMs
#
# Run from a workstation with Azure CLI installed and az login completed.
# Prerequisites: 00-prepare-image.ps1 must have been completed first.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"

az account set --subscription $SUBSCRIPTION_ID

# Helper: tag string for az CLI
$tagArgs = $TAGS.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }

Write-Host "=== Step 1: Networking ===" -ForegroundColor Cyan

# NSG with RDP locked to your public IP
$myPublicIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
Write-Host "Locking RDP to your current IP: $myPublicIP"

az network nsg create `
    --resource-group $RESOURCE_GROUP `
    --name $NSG_NAME `
    --location $LOCATION `
    --tags @tagArgs `
    --output none

az network nsg rule create `
    --resource-group $RESOURCE_GROUP `
    --nsg-name $NSG_NAME `
    --name "Allow-RDP-From-Admin" `
    --priority 1000 `
    --protocol Tcp `
    --direction Inbound `
    --source-address-prefixes "$myPublicIP/32" `
    --source-port-ranges "*" `
    --destination-address-prefixes "*" `
    --destination-port-ranges 3389 `
    --access Allow `
    --output none

az network nsg rule create `
    --resource-group $RESOURCE_GROUP `
    --nsg-name $NSG_NAME `
    --name "Allow-HTTPS-Inbound" `
    --priority 1010 `
    --protocol Tcp `
    --direction Inbound `
    --source-address-prefixes "$myPublicIP/32" `
    --source-port-ranges "*" `
    --destination-address-prefixes "*" `
    --destination-port-ranges 443 `
    --access Allow `
    --output none

az network nsg rule create `
    --resource-group $RESOURCE_GROUP `
    --nsg-name $NSG_NAME `
    --name "Allow-VNet-Internal" `
    --priority 900 `
    --protocol "*" `
    --direction Inbound `
    --source-address-prefixes "VirtualNetwork" `
    --source-port-ranges "*" `
    --destination-address-prefixes "VirtualNetwork" `
    --destination-port-ranges "*" `
    --access Allow `
    --output none

# VNet + subnets
az network vnet create `
    --resource-group $RESOURCE_GROUP `
    --name $VNET_NAME `
    --location $LOCATION `
    --address-prefixes $VNET_PREFIX `
    --subnet-name $SUBNET_NAME `
    --subnet-prefixes $SUBNET_PREFIX `
    --tags @tagArgs `
    --output none

# DNS set to DC static IP so domain-joined VMs resolve correctly after DC is promoted
az network vnet update `
    --resource-group $RESOURCE_GROUP `
    --name $VNET_NAME `
    --dns-servers $DC_IP `
    --output none

Write-Host "VNet + NSG created." -ForegroundColor Green

# =============================================================================
# Step 2: Storage account for VM configuration scripts
# =============================================================================
Write-Host "=== Step 2: Script Storage ===" -ForegroundColor Cyan

az storage account create `
    --name $STORAGE_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION `
    --sku Standard_LRS `
    --kind StorageV2 `
    --allow-blob-public-access false `
    --tags @tagArgs `
    --output none

az storage container create `
    --name $STORAGE_CONTAINER `
    --account-name $STORAGE_ACCOUNT `
    --auth-mode login `
    --output none

Write-Host "Script storage account: $STORAGE_ACCOUNT" -ForegroundColor Green

# =============================================================================
# Step 3: Upload all VM configuration scripts to blob storage
# =============================================================================
Write-Host "=== Step 3: Upload configuration scripts ===" -ForegroundColor Cyan

$scriptFiles = @(
    "02-config-dc.ps1",
    "03-config-rootca.ps1",
    "04-config-issuingca.ps1",
    "05-config-webserver.ps1",
    "06-enable-mlkem-tls.ps1"
)

foreach ($f in $scriptFiles) {
    $localPath = Join-Path $PSScriptRoot $f
    if (Test-Path $localPath) {
        az storage blob upload `
            --account-name $STORAGE_ACCOUNT `
            --container-name $STORAGE_CONTAINER `
            --name $f `
            --file $localPath `
            --auth-mode login `
            --overwrite `
            --output none
        Write-Host "  Uploaded: $f"
    }
}

# =============================================================================
# Step 4: Deploy 4 VMs from the custom vNext image
# =============================================================================
Write-Host "=== Step 4: Deploy VMs ===" -ForegroundColor Cyan

# Resolve image ID from gallery
$imageId = az sig image-version show `
    --resource-group $RESOURCE_GROUP `
    --gallery-name $IMAGE_GALLERY_NAME `
    --gallery-image-definition $IMAGE_DEF_NAME `
    --gallery-image-version $IMAGE_VERSION `
    --query "id" -o tsv

if (-not $imageId) {
    Write-Error "Could not find image $IMAGE_DEF_NAME version $IMAGE_VERSION in gallery $IMAGE_GALLERY_NAME. Run 00-prepare-image.ps1 first."
    exit 1
}

# VM definitions: [name, static-IP (or "dynamic"), data-disk-GB]
$vms = @(
    @{ Name = $VM_ROOTCA;     IP = "10.10.1.20"; DataDiskGB = 0  },
    @{ Name = $VM_DC;         IP = $DC_IP;        DataDiskGB = 0  },
    @{ Name = $VM_ISSUINGCA;  IP = "10.10.1.30"; DataDiskGB = 0  },
    @{ Name = $VM_WEBSERVER;  IP = "10.10.1.40"; DataDiskGB = 0  }
)

foreach ($vm in $vms) {
    $vmName  = $vm.Name
    $vmNic   = "$vmName-nic"
    $vmPip   = "$vmName-pip"
    $vmOsDisk = "$vmName-osdisk"

    Write-Host "  Creating NIC + public IP for $vmName..."

    az network public-ip create `
        --resource-group $RESOURCE_GROUP `
        --name $vmPip `
        --location $LOCATION `
        --sku Standard `
        --allocation-method Static `
        --tags @tagArgs `
        --output none

    az network nic create `
        --resource-group $RESOURCE_GROUP `
        --name $vmNic `
        --location $LOCATION `
        --vnet-name $VNET_NAME `
        --subnet $SUBNET_NAME `
        --private-ip-address $vm.IP `
        --public-ip-address $vmPip `
        --network-security-group $NSG_NAME `
        --tags @tagArgs `
        --output none

    Write-Host "  Deploying VM: $vmName (this takes ~3-5 min)..."

    az vm create `
        --resource-group $RESOURCE_GROUP `
        --name $vmName `
        --location $LOCATION `
        --nics $vmNic `
        --image $imageId `
        --size $VM_SIZE `
        --admin-username $ADMIN_USER `
        --admin-password $ADMIN_PASS `
        --os-disk-name $vmOsDisk `
        --os-disk-size-gb 128 `
        --storage-sku Premium_LRS `
        --tags @tagArgs `
        --output none

    Write-Host "  VM $vmName deployed." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== All VMs deployed ===" -ForegroundColor Green
Write-Host ""

# Print connection info
foreach ($vm in $vms) {
    $pip = az network public-ip show `
        --resource-group $RESOURCE_GROUP `
        --name "$($vm.Name)-pip" `
        --query "ipAddress" -o tsv
    Write-Host "$($vm.Name.PadRight(25)) Public IP: $pip   Private IP: $($vm.IP)"
}

Write-Host ""
Write-Host "Next step: run 02-config-dc.ps1 (connects via Azure VM Run Command)"
