. "$PSScriptRoot\00-common.ps1"

Write-Step "Installing AD DS and promoting domain controller..."

$dcPromotion = {
    param($DomainFqdn, $Netbios, $SafeModePass)

    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
    $secureSafe = ConvertTo-SecureString $SafeModePass -AsPlainText -Force

    Install-ADDSForest `
        -DomainName $DomainFqdn `
        -DomainNetbiosName $Netbios `
        -InstallDns `
        -SafeModeAdministratorPassword $secureSafe `
        -NoRebootOnCompletion:$false `
        -Force
}

Invoke-InVmLocal -VmName $VmDc -ArgumentList $DomainName, $DomainNetbios, $SafeModePasswordPlain -ScriptBlock $dcPromotion

Write-Step "Waiting for DC reboot..."
Start-Sleep -Seconds 60
Wait-VMReadyForDirect -VmName $VmDc -TimeoutSeconds 900

Write-Step "Verifying AD DS and DNS services..."
Invoke-InVmLocal -VmName $VmDc -ScriptBlock {
    Get-Service ADWS, DNS, Netlogon | Select-Object Name, Status | Format-Table -AutoSize
}

Write-Step "Creating domain service account for enrollment ops..."
Invoke-InVmDomain -VmName $VmDc -ScriptBlock {
    Import-Module ActiveDirectory
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-ca-enroll'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name "svc-ca-enroll" `
            -SamAccountName "svc-ca-enroll" `
            -UserPrincipalName "svc-ca-enroll@pqclab.local" `
            -AccountPassword (ConvertTo-SecureString "P@ssw0rd-SvcCA-2026!" -AsPlainText -Force) `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -Description "Service account for PKI test operations"
    }
}

Write-Step "Domain controller setup complete."

