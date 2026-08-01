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
$VM_CLIENT        = "$PREFIX-win11client"             # Windows 11 PQC test client

# B2ms = 2 vCPU, 8GB RAM — adequate for a test lab
# Use Standard_D2s_v5 if you need better performance
$VM_SIZE          = "Standard_B2ms"

# ----- Deployment Mode -------------------------------------------------------
# "GA"    — Windows Server 2025 GA + KB5087539 (ML-DSA) + KB5099536 (ML-KEM TLS) [RECOMMENDED]
#           Requires only production Windows Update — no Insider subscription needed.
# "vNext" — Windows Server vNext Insider Preview 29550+  (all PQC features built-in)
$DEPLOYMENT_MODE = "GA"

# ----- Custom Images ---------------------------------------------------------
$IMAGE_GALLERY_NAME = "$PREFIX-gallery"

# GA path — Server 2025 + KB5099536 (OS build 26100.33158, July 14 2026)
$GA_IMAGE_DEF_NAME  = "WinServer2025-GA"
$GA_IMAGE_VERSION   = "26100.33158.$(Get-Date -Format 'yyyyMMdd')"   # e.g. 26100.33158.20260801

# vNext path — Windows Server vNext Insider Preview 29550+
$VNEXT_IMAGE_DEF_NAME = "WinServerVNext-29550"
$VNEXT_IMAGE_VERSION  = "29550.0.$(Get-Date -Format 'yyyyMMdd')"     # e.g. 29550.0.20260801

# Active image — derived automatically from DEPLOYMENT_MODE (do not edit these two lines)
$IMAGE_DEF_NAME = if ($DEPLOYMENT_MODE -eq "GA") { $GA_IMAGE_DEF_NAME   } else { $VNEXT_IMAGE_DEF_NAME  }
$IMAGE_VERSION  = if ($DEPLOYMENT_MODE -eq "GA") { $GA_IMAGE_VERSION    } else { $VNEXT_IMAGE_VERSION   }

# Windows 11 client image — created using the same process as 00-prepare-image.ps1.
# As of July 14, 2026, GA Win11 24H2/25H2 + KB5101650 (build 26100.8524+) is sufficient.
# Win11 Insider Preview 26100.8514+ also works (original minimum, still valid).
# Set WIN11_IMAGE_VERSION after you upload the image to the gallery.
$WIN11_IMAGE_DEF_NAME = "Win11-24H2-26100"     # rename to match your actual gallery image def
$WIN11_IMAGE_VERSION  = "26100.0.$(Get-Date -Format 'yyyyMMdd')"  # e.g. 26100.0.20260801

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
    Build       = if ($DEPLOYMENT_MODE -eq "GA") { "Server2025-GA-26100.33158" } else { "vNext-29550" }
    CreatedDate = (Get-Date -Format "yyyy-MM-dd")
}
