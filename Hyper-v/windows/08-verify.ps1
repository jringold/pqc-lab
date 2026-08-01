. "$PSScriptRoot\00-common.ps1"

Write-Step "Verifying Issuing CA status..."
Invoke-InVmDomain -VmName $VmIssuingCa -ScriptBlock {
    certutil -ping
    Get-Service certsvc | Select-Object Name, Status | Format-Table -AutoSize
    Get-ChildItem cert:\LocalMachine\CA | Select-Object Subject, Issuer, NotAfter | Format-Table -AutoSize
}

Write-Step "Verifying web TLS certificate and IIS binding..."
Invoke-InVmDomain -VmName $VmWeb -ArgumentList $DomainName -ScriptBlock {
    param($DomainFqdn)
    Import-Module WebAdministration
    Get-WebBinding -Name "Default Web Site" -Protocol https | Format-Table -AutoSize

    $cert = Get-ChildItem cert:\LocalMachine\My | Where-Object Subject -Like "*$env:COMPUTERNAME*" | Sort-Object NotBefore -Descending | Select-Object -First 1
    $cert | Select-Object Subject, Issuer, NotAfter, @{Name='SignatureAlgorithm';Expression={$_.SignatureAlgorithm.FriendlyName}} | Format-List

    Invoke-WebRequest -Uri "https://$env:COMPUTERNAME.$DomainFqdn" -UseBasicParsing -SkipCertificateCheck | Select-Object StatusCode, StatusDescription
    Get-TlsEccCurve | Select-Object Name, Priority | Format-Table -AutoSize
}

Write-Step "Lab verification completed."
Write-Host ""
Write-Host "Test from a client VM (preferred) or host browser:" -ForegroundColor Yellow
Write-Host "  https://webserver01.$DomainName"
Write-Host ""
Write-Host "Expected profile:" -ForegroundColor Yellow
Write-Host "  - Certificate signature: ML-DSA-65 (chain to ML-DSA-87 root)"
Write-Host "  - TLS key exchange group: x25519_mlkem768"
Write-Host "  - Protocol: TLS 1.3"

