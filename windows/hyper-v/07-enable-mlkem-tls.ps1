. "$PSScriptRoot\00-common.ps1"

$mlKemScript = {
    Enable-TlsEccCurve -Name "x25519_mlkem768"
    Enable-TlsEccCurve -Name "secp256r1_mlkem768"
    Enable-TlsEccCurve -Name "secp384r1_mlkem1024"

    Set-TlsEccCurve -Name @(
        "x25519_mlkem768",
        "secp256r1_mlkem768",
        "secp384r1_mlkem1024",
        "NistP384",
        "NistP256",
        "x25519"
    )

    $serverKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server"
    if (-not (Test-Path $serverKey)) { New-Item $serverKey -Force | Out-Null }
    New-ItemProperty -Path $serverKey -Name Enabled -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $serverKey -Name DisabledByDefault -Value 0 -PropertyType DWord -Force | Out-Null

    $clientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
    if (-not (Test-Path $clientKey)) { New-Item $clientKey -Force | Out-Null }
    New-ItemProperty -Path $clientKey -Name Enabled -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $clientKey -Name DisabledByDefault -Value 0 -PropertyType DWord -Force | Out-Null

    Get-TlsEccCurve | Select-Object Name, Priority | Format-Table -AutoSize
}

Write-Step "Enabling ML-KEM groups on web server..."
Invoke-InVmDomain -VmName $VmWeb -ScriptBlock $mlKemScript

Write-Step "Enabling ML-KEM groups on domain controller..."
Invoke-InVmDomain -VmName $VmDc -ScriptBlock $mlKemScript

Write-Step "Restarting updated VMs..."
Restart-VmAndWait -VmName $VmWeb
Restart-VmAndWait -VmName $VmDc

Write-Step "ML-KEM enablement complete."

