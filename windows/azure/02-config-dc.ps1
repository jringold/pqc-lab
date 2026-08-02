# =============================================================================
# PQC PKI Lab — Phase 2: Configure Domain Controller
# Runs the AD DS installation INSIDE the DC VM via Azure VM Run Command.
#
# This script runs from your LOCAL workstation (Azure CLI required).
# The inner script block is injected into the DC VM and executed there.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# =============================================================================
# Inner script — runs INSIDE the DC VM
# =============================================================================
$innerScript = @"
param(
    [string]\$DomainName      = "$DOMAIN_NAME",
    [string]\$NetbiosName     = "$DOMAIN_NETBIOS",
    [string]\$SafeModePass    = "$SAFE_MODE_PASS"
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[DC-SETUP `$(Get-Date -Format HH:mm:ss)] `$msg" }

# --- 1. Set static hostname ---
Log "Setting hostname to dc01..."
Rename-Computer -NewName "dc01" -Force -ErrorAction SilentlyContinue

# --- 2. Install AD DS role ---
Log "Installing AD-Domain-Services role..."
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -Confirm:`$false

# --- 3. Promote to Domain Controller ---
Log "Promoting to new forest: `$DomainName..."
`$secureSafe = ConvertTo-SecureString `$SafeModePass -AsPlainText -Force

Install-ADDSForest ``
    -DomainName `$DomainName ``
    -DomainNetbiosName `$NetbiosName ``
    -InstallDns ``
    -SafeModeAdministratorPassword `$secureSafe ``
    -Force

# Note: VM will reboot automatically after this cmdlet completes.
Log "Forest promotion initiated — VM will reboot."
"@

Write-Host "=== Injecting DC configuration script via Run Command ===" -ForegroundColor Cyan
Write-Host "This may take 5-10 minutes (AD DS install + forest promotion + reboot)..."

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_DC `
    --command-id RunPowerShellScript `
    --scripts $innerScript

Write-Host "DC promotion initiated. Waiting 3 minutes for reboot..." -ForegroundColor Yellow
Start-Sleep -Seconds 180

# =============================================================================
# Post-reboot: verify DC is healthy
# =============================================================================
$verifyScript = @"
Get-ADDomainController -Discover -Service PrimaryDC | Select-Object Name, Domain, Site
Get-Service ADWS, DNS, Netlogon | Select-Object Name, Status
"@

Write-Host "=== Verifying DC health after reboot ===" -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_DC `
    --command-id RunPowerShellScript `
    --scripts $verifyScript

# =============================================================================
# Create an AD service account for CA enrollment
# =============================================================================
$caAccountScript = @"
Import-Module ActiveDirectory
New-ADUser ``
    -Name "svc-ca-enroll" ``
    -SamAccountName "svc-ca-enroll" ``
    -UserPrincipalName "svc-ca-enroll@$DOMAIN_NAME" ``
    -AccountPassword (ConvertTo-SecureString "$SVC_CA_PASS" -AsPlainText -Force) ``
    -PasswordNeverExpires `$true ``
    -Enabled `$true ``
    -Description "Service account for CA auto-enrollment"
Write-Host "Service account svc-ca-enroll created."
"@

Write-Host "=== Creating CA service account ===" -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_DC `
    --command-id RunPowerShellScript `
    --scripts $caAccountScript

Write-Host ""
Write-Host "=== DC configuration complete ===" -ForegroundColor Green
Write-Host "Domain  : $DOMAIN_NAME"
Write-Host "DC VM   : $VM_DC  ($DC_IP)"
Write-Host ""
Write-Host "IMPORTANT: Update the VNet DNS server to $DC_IP if not already done."
Write-Host "Next step: run 03-config-rootca.ps1"
