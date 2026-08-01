# =============================================================================
# PQC PKI Lab — Azure Deployment Variables
# Edit this file before running any other scripts.
# =============================================================================

# ----- Azure Subscription & Location ----------------------------------------
$SUBSCRIPTION_ID  = "YOUR_SUBSCRIPTION_ID"      # az account list --output table
$LOCATION         = "eastus"                     # az account list-locations -o table
$RESOURCE_GROUP   = "rg-pqc-lab"

# ----- Naming Prefix ---------------------------------------------------------
$PREFIX           = "pqclab"                     # Keep short — used in all resource names

# ----- Networking ------------------------------------------------------------
$VNET_NAME        = "$PREFIX-vnet"
$VNET_PREFIX      = "10.10.0.0/16"
$SUBNET_NAME      = "$PREFIX-subnet"
$SUBNET_PREFIX    = "10.10.1.0/24"
$BASTION_SUBNET   = "10.10.254.0/27"            # /27 minimum required by Azure Bastion
$NSG_NAME         = "$PREFIX-nsg"

# ----- Admin Credentials (CHANGE THESE) -------------------------------------
$ADMIN_USER       = "labadmin"
$ADMIN_PASS       = "P@ssw0rd-PQCLab2026!"      # Must meet Azure complexity rules

# ----- VM Names & Sizes ------------------------------------------------------
$VM_ROOTCA        = "$PREFIX-rootca"
$VM_DC            = "$PREFIX-dc"
$VM_ISSUINGCA     = "$PREFIX-issuingca"
$VM_WEBSERVER     = "$PREFIX-webserver"
$VM_CLIENT        = "$PREFIX-win11client"             # Windows 11 Insider Preview PQC test client

# B2ms = 2 vCPU, 8GB RAM — adequate for a test lab
# Use Standard_D2s_v5 if you need better performance
$VM_SIZE          = "Standard_B2ms"

# ----- Custom Images ---------------------------------------------------------
# Server vNext image — created by 00-prepare-image.ps1 from Windows Server vNext ISO
$IMAGE_GALLERY_NAME  = "$PREFIX-gallery"
$IMAGE_DEF_NAME      = "WinServerVNext-29550"
$IMAGE_VERSION       = "29550.0.$(Get-Date -Format 'yyyyMMdd')"  # e.g. 29550.0.20260728

# Windows 11 Insider Preview image — create using the same process as 00-prepare-image.ps1
# but sourced from the Win11 Insider Preview ISO (build 26100.8514+).
# Set WIN11_IMAGE_VERSION after you upload the image to the gallery.
$WIN11_IMAGE_DEF_NAME = "Win11InsiderPreview-26100"
$WIN11_IMAGE_VERSION  = "26100.0.$(Get-Date -Format 'yyyyMMdd')"  # e.g. 26100.0.20260728

# ----- Domain ----------------------------------------------------------------
$DOMAIN_NAME      = "pqclab.local"
$DOMAIN_NETBIOS   = "PQCLAB"
$DC_IP            = "10.10.1.10"                # Static IP assigned to DC VM
$SAFE_MODE_PASS   = "P@ssw0rd-DSRM2026!"       # DSRM password (different from admin)

# ----- Storage (for scripts) -------------------------------------------------
$STORAGE_ACCOUNT  = "${PREFIX}scripts$(Get-Random -Minimum 1000 -Maximum 9999)"
$STORAGE_CONTAINER = "scripts"

# ----- Tags ------------------------------------------------------------------
$TAGS = @{
    Project     = "PQC-PKI-Lab"
    Environment = "Testing"
    Build       = "vNext-29550"
    CreatedDate = (Get-Date -Format "yyyy-MM-dd")
}
