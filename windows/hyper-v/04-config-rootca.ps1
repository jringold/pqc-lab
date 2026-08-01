. "$PSScriptRoot\00-common.ps1"

Write-Step "Configuring standalone Root CA (ML-DSA-87)..."

Invoke-InVmLocal -VmName $VmRootCa -ScriptBlock {
    Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null

    Install-AdcsCertificationAuthority `
        -CAType StandaloneRootCA `
        -CACommonName "PQCLab Root CA" `
        -KeyLength 20736 `
        -HashAlgorithm NoHash `
        -CryptoProviderName "ML-DSA:87#Microsoft Software Key Storage Provider" `
        -ValidityPeriod Years `
        -ValidityPeriodUnits 10 `
        -Force

    certutil -setreg CA\CRLPeriodUnits 1
    certutil -setreg CA\CRLPeriod "Weeks"
    certutil -setreg CA\CRLDeltaPeriodUnits 0
    certutil -setreg CA\CRLDeltaPeriod "Days"
    Restart-Service certsvc
    certutil -crl

    New-Item -ItemType Directory -Path "C:\PKI-Export" -Force | Out-Null
    certutil -ca.cert "C:\PKI-Export\RootCA.cer"
    $crl = Get-ChildItem "C:\Windows\System32\CertSrv\CertEnroll" -Filter "*.crl" | Select-Object -First 1
    if ($crl) { Copy-Item $crl.FullName "C:\PKI-Export\RootCA.crl" -Force }
}

Write-Step "Copying Root CA artifacts to host staging..."
Ensure-Folder -Path $HostStagingPath

$cred = Get-LocalAdminCredential
$rootSession = New-PSSession -VMName $VmRootCa -Credential $cred
Copy-Item -FromSession $rootSession -Path "C:\PKI-Export\RootCA.cer" -Destination (Join-Path $HostStagingPath "RootCA.cer") -Force
Copy-Item -FromSession $rootSession -Path "C:\PKI-Export\RootCA.crl" -Destination (Join-Path $HostStagingPath "RootCA.crl") -Force
Remove-PSSession $rootSession

Write-Step "Root CA setup complete. Next run 05-config-issuingca.ps1."

