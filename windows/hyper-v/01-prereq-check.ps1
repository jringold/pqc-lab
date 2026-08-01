. "$PSScriptRoot\00-common.ps1"

Write-Step "Checking Hyper-V host prerequisites..."

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell module not available. Install Hyper-V role/tools first."
}

if (-not (Test-Path $BaseVhdPath)) {
    throw "Base VHDX not found at '$BaseVhdPath'. Update 00-variables.ps1."
}

Ensure-Folder -Path $VmRootPath
Ensure-Folder -Path $HostStagingPath

$vms = @($VmRootCa, $VmDc, $VmIssuingCa, $VmWeb)
foreach ($vm in $vms) {
    if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
        Write-Host "VM already exists: $vm" -ForegroundColor Yellow
    } else {
        Write-Host "VM not present yet: $vm" -ForegroundColor Green
    }
}

Write-Step "Prerequisite check complete."

