. "$PSScriptRoot\00-common.ps1"

Write-Host "This will destroy the Hyper-V PQC lab resources." -ForegroundColor Red
$confirm = Read-Host "Type DELETE to continue"
if ($confirm -ne "DELETE") {
    Write-Host "Cancelled."
    exit 0
}

foreach ($vm in @($VmRootCa, $VmDc, $VmIssuingCa, $VmWeb)) {
    if (Get-VM -Name $vm -ErrorAction SilentlyContinue) {
        if ((Get-VM -Name $vm).State -eq "Running") {
            Stop-VM -Name $vm -TurnOff -Force
        }
        Remove-VM -Name $vm -Force
        Write-Host "Removed VM: $vm"
    }
}

if (Test-Path $VmRootPath) {
    Remove-Item -Path $VmRootPath -Recurse -Force
    Write-Host "Removed lab path: $VmRootPath"
}

if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
    Remove-NetNat -Name $NatName -Confirm:$false
    Write-Host "Removed NAT: $NatName"
}

if (Get-VMSwitch -Name $VMSwitchName -ErrorAction SilentlyContinue) {
    Remove-VMSwitch -Name $VMSwitchName -Force
    Write-Host "Removed switch: $VMSwitchName"
}

Write-Host "Cleanup complete."

