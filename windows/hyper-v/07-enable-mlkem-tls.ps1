. "$PSScriptRoot\00-common.ps1"

# =============================================================================
# ML-KEM hybrid TLS group enablement
# Supported on:
#   Server side — Windows Server vNext 29550+  OR  Windows Server 2025 GA + KB5099536
#                 (KB5099536, July 14 2026, OS Build 26100.33158 backported ML-KEM to GA)
#   Client side — Win11 24H2/25H2 GA + KB5101650  OR  Win11 26H1 GA + KB5095091
#                 OR Win11 Insider Preview 26100.8514+ (still valid, original minimum)
# All three ML-KEM hybrid groups use TLS 1.3 only and are disabled by default.
# BOTH server AND client must enable the groups for negotiation to succeed.
# =============================================================================
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

