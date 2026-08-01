. "$PSScriptRoot\00-common.ps1"

Write-Step "Joining Issuing CA VM to domain..."

$domainJoinScript = {
    param($DomainFqdn, $DomainNetbios, $AdminUser, $AdminPass)
    $secure = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    $cred = [pscredential]::new("$DomainNetbios\$AdminUser", $secure)
    Add-Computer -DomainName $DomainFqdn -Credential $cred -Force -Restart
}

Invoke-InVmLocal -VmName $VmIssuingCa -ArgumentList $DomainName, $DomainNetbios, $DomainAdminUser, $LocalAdminPasswordPlain -ScriptBlock $domainJoinScript

Write-Step "Waiting for Issuing CA reboot after domain join..."
Start-Sleep -Seconds 60
Wait-VMReadyForDirect -VmName $VmIssuingCa -TimeoutSeconds 600

Write-Step "Copying Root CA cert + CRL from host to Issuing CA..."
$domainCred = Get-DomainAdminCredential
$issSession = New-PSSession -VMName $VmIssuingCa -Credential $domainCred
Invoke-Command -Session $issSession -ScriptBlock { New-Item -ItemType Directory -Path "C:\PKI-Import" -Force | Out-Null; New-Item -ItemType Directory -Path "C:\PKI-Export" -Force | Out-Null }
Copy-Item -ToSession $issSession -Path (Join-Path $HostStagingPath "RootCA.cer") -Destination "C:\PKI-Import\RootCA.cer" -Force
Copy-Item -ToSession $issSession -Path (Join-Path $HostStagingPath "RootCA.crl") -Destination "C:\PKI-Import\RootCA.crl" -Force
Remove-PSSession $issSession

Write-Step "Installing Enterprise Subordinate CA (ML-DSA-65) and generating CSR..."
Invoke-InVmDomain -VmName $VmIssuingCa -ScriptBlock {
    Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null

    certutil -addstore Root "C:\PKI-Import\RootCA.cer"
    certutil -addstore CA "C:\PKI-Import\RootCA.cer"

    Install-AdcsCertificationAuthority `
        -CAType EnterpriseSubordinateCA `
        -CACommonName "PQCLab Issuing CA" `
        -KeyLength 15616 `
        -HashAlgorithm NoHash `
        -CryptoProviderName "ML-DSA:65#Microsoft Software Key Storage Provider" `
        -OutputCertRequestFile "C:\PKI-Export\SubCA.req" `
        -Force
}

Write-Step "Copying SubCA.req from Issuing CA to host staging..."
$issSession = New-PSSession -VMName $VmIssuingCa -Credential $domainCred
Copy-Item -FromSession $issSession -Path "C:\PKI-Export\SubCA.req" -Destination (Join-Path $HostStagingPath "SubCA.req") -Force
Remove-PSSession $issSession

Write-Step "Submitting and issuing SubCA.req on Root CA..."
$rootCred = Get-LocalAdminCredential
$rootSession = New-PSSession -VMName $VmRootCa -Credential $rootCred
Invoke-Command -Session $rootSession -ScriptBlock { New-Item -ItemType Directory -Path "C:\PKI-Import" -Force | Out-Null; New-Item -ItemType Directory -Path "C:\PKI-Export" -Force | Out-Null }
Copy-Item -ToSession $rootSession -Path (Join-Path $HostStagingPath "SubCA.req") -Destination "C:\PKI-Import\SubCA.req" -Force
Invoke-Command -Session $rootSession -ScriptBlock {
    $submitOut = certutil -submit "C:\PKI-Import\SubCA.req"
    $reqLine = $submitOut | Select-String "RequestId:"
    if (-not $reqLine) { throw "Could not parse RequestId from certutil output." }
    $reqId = ($reqLine.ToString().Split(":")[1]).Trim()
    certutil -resubmit $reqId
    certutil -retrieve $reqId "C:\PKI-Export\SubCA.cer"
}
Copy-Item -FromSession $rootSession -Path "C:\PKI-Export\SubCA.cer" -Destination (Join-Path $HostStagingPath "SubCA.cer") -Force
Remove-PSSession $rootSession

Write-Step "Installing signed SubCA certificate on Issuing CA..."
$issSession = New-PSSession -VMName $VmIssuingCa -Credential $domainCred
Copy-Item -ToSession $issSession -Path (Join-Path $HostStagingPath "SubCA.cer") -Destination "C:\PKI-Import\SubCA.cer" -Force
Invoke-Command -Session $issSession -ScriptBlock {
    certreq -accept "C:\PKI-Import\SubCA.cer"
    certutil -dspublish -f "C:\PKI-Import\RootCA.cer" RootCA
    Start-Service certsvc
    certutil -ping
}
Remove-PSSession $issSession

Write-Step "Issuing CA setup complete."

