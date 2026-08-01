# =============================================================================
# PQC PKI Lab — Cleanup: Tear down all Azure resources
# Run this when you are done testing to avoid ongoing charges.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

Write-Host "=== This will DELETE the entire resource group: $RESOURCE_GROUP ===" -ForegroundColor Red
Write-Host "All VMs, disks, network resources, and storage will be permanently removed."
$confirm = Read-Host "Type 'DELETE' to confirm"

if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "Deleting resource group $RESOURCE_GROUP (this takes ~5 minutes)..."
az group delete --name $RESOURCE_GROUP --yes --no-wait

Write-Host "Deletion initiated. Resources will be removed in the background." -ForegroundColor Green
