. "$PSScriptRoot\00-common.ps1"

Write-Step "Joining Web Server VM to domain..."

$domainJoinScript = {
    param($DomainFqdn, $DomainNetbios, $AdminUser, $AdminPass)
    $secure = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    $cred = [pscredential]::new("$DomainNetbios\$AdminUser", $secure)
    Add-Computer -DomainName $DomainFqdn -Credential $cred -Force -Restart
}

Invoke-InVmLocal -VmName $VmWeb -ArgumentList $DomainName, $DomainNetbios, $DomainAdminUser, $LocalAdminPasswordPlain -ScriptBlock $domainJoinScript
Start-Sleep -Seconds 60
Wait-VMReadyForDirect -VmName $VmWeb

Write-Step "Creating and publishing PQC Web Server template on Issuing CA..."
Invoke-InVmDomain -VmName $VmIssuingCa -ScriptBlock {
    Import-Module ActiveDirectory

    $configNC = (Get-ADRootDSE).configurationNamingContext
    $templateContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"

    if (-not ([adsi]::Exists("LDAP://CN=PQCWebServer,$templateContainer"))) {
        $source = [adsi]"LDAP://CN=WebServer,$templateContainer"
        $copy = $source.psbase.CopyTo("LDAP://CN=PQCWebServer,$templateContainer")
        $copy.Put("cn", "PQCWebServer")
        $copy.Put("displayName", "PQC Web Server")
        $copy.Put("pKIDefaultKeySpec", 2) # signature
        $copy.Put("msPKI-Minimal-Key-Size", 15616)
        $copy.Put("pKIDefaultCSPs", @("1,ML-DSA:65#Microsoft Software Key Storage Provider"))
        $copy.Put("pKIExtendedKeyUsage", @("1.3.6.1.5.5.7.3.1")) # Server Auth only
        $copy.SetInfo()
    }

    if (-not (Get-CATemplate | Where-Object Name -eq "PQCWebServer")) {
        Add-CATemplate -Name "PQCWebServer"
    }
}

Write-Step "Installing IIS and enrolling ML-DSA TLS certificate on web server..."
Invoke-InVmDomain -VmName $VmWeb -ArgumentList $DomainName, $VmIssuingCa -ScriptBlock {
    param($DomainFqdn, $IssuingVmName)

    Install-WindowsFeature Web-Server, Web-Mgmt-Console | Out-Null
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null

    $subjectName = "CN=$env:COMPUTERNAME.$DomainFqdn"
    $caConfig = "$IssuingVmName.$DomainFqdn\PQCLab Issuing CA"

    $inf = @"
[Version]
Signature="$Windows NT$"

[NewRequest]
Subject = "$subjectName"
KeyLength = 15616
HashAlgorithm = NoHash
MachineKeySet = True
RequestType = PKCS10
KeySpec = 2
ProviderName = "ML-DSA:65#Microsoft Software Key Storage Provider"

[RequestAttributes]
CertificateTemplate = PQCWebServer

[EnhancedKeyUsageExtension]
OID=1.3.6.1.5.5.7.3.1
"@

    $infPath = "C:\Temp\pqc-web.inf"
    $reqPath = "C:\Temp\pqc-web.req"
    $cerPath = "C:\Temp\pqc-web.cer"
    $inf | Set-Content -Path $infPath -Encoding Ascii

    certreq -new $infPath $reqPath
    certreq -submit -config $caConfig $reqPath $cerPath
    certreq -accept $cerPath

    Import-Module WebAdministration
    Remove-WebBinding -Name "Default Web Site" -Protocol https -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -Protocol https -Port 443

    $cert = Get-ChildItem cert:\LocalMachine\My | Where-Object Subject -Like "*$env:COMPUTERNAME*" | Sort-Object NotBefore -Descending | Select-Object -First 1
    if (-not $cert) { throw "No web certificate found after enrollment." }

    $sslPath = "IIS:\SslBindings\0.0.0.0!443"
    if (Test-Path $sslPath) { Remove-Item $sslPath -Force }
    Get-Item "cert:\LocalMachine\My\$($cert.Thumbprint)" | New-Item $sslPath | Out-Null
}

Write-Step "Web server setup complete."

