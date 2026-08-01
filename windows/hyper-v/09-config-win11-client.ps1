. "$PSScriptRoot\00-common.ps1"

# =============================================================================
# PQC PKI Lab on Hyper-V — Phase 9: Configure Windows 11 Client
# Domain-joins the Win11 client VM, enables ML-KEM TLS groups, applies Root CA
# trust via Group Policy, and runs automated + guided TLS verification.
#
# Prerequisites:
#   - Scripts 01 through 08 must be complete.
#   - $Win11BaseVhdPath must point to a prepared Win11 VHDX. As of July 14, 2026:
#       GA Win11 24H2/25H2 with KB5101650 (build 26100.8524+) is sufficient.
#       GA Win11 26H1 with KB5095091 is sufficient.
#       Win11 Insider Preview build 26100.8514+ also works (original minimum).
#       Insider Preview is NO LONGER REQUIRED for ML-KEM TLS support.
#   - The Win11 client VM must have been created by 02-new-lab-vms.ps1.
#
# Why Win11 and not a second Server VM?
#   - The TLS ML-KEM negotiation requires BOTH endpoints to advertise the hybrid
#     groups in ClientHello. A Win11 Insider client tests the realistic user path.
#   - Microsoft Edge on Win11 exposes the negotiated key-exchange group in the
#     F12 DevTools Security tab, which is the primary human-readable PQC proof.
# =============================================================================

# ---- Step 1: Domain join the Win11 client -----------------------------------
Write-Step "Domain-joining Win11 client..."

$domainJoinScript = {
    param($DomainFqdn, $DomainNetbios, $AdminUser, $AdminPass, $DcIp)

    # Set DNS to the domain controller before attempting join
    $nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
    if ($nic) {
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($DcIp)
    }

    # Rename before joining so AD gets a clean computer name
    if ($env:COMPUTERNAME -ne "win11client") {
        Rename-Computer -NewName "win11client" -Force
    }

    $secure = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    $cred   = [pscredential]::new("$DomainNetbios\$AdminUser", $secure)
    Add-Computer -DomainName $DomainFqdn -Credential $cred -Force -Restart
}

Invoke-InVmLocal -VmName $VmClient `
    -ArgumentList $DomainName, $DomainNetbios, $DomainAdminUser, $LocalAdminPasswordPlain, $DcIp `
    -ScriptBlock $domainJoinScript

Start-Sleep -Seconds 60
Wait-VMReadyForDirect -VmName $VmClient

# ---- Step 2: Enable ML-KEM hybrid TLS groups (client side) -----------------
Write-Step "Enabling ML-KEM TLS groups on Win11 client..."

Invoke-InVmDomain -VmName $VmClient -ScriptBlock {
    # As of July 14, 2026 (KB5101650): GA Win11 24H2/25H2 supports these same cmdlets.
    # Server vNext 29550+ OR Server 2025 GA + KB5099536 supports the server side.
    # Both sides must advertise ML-KEM for negotiation to succeed.
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

    # TLS 1.3 Client must be explicitly enabled (ML-KEM is TLS 1.3-only)
    $clientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
    if (-not (Test-Path $clientKey)) { New-Item -Path $clientKey -Force | Out-Null }
    New-ItemProperty -Path $clientKey -Name "Enabled"           -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $clientKey -Name "DisabledByDefault"  -Value 0 -PropertyType DWord -Force | Out-Null

    # Enable Schannel verbose event logging (EventID 36880 = TLS session established).
    # Level 7 captures error + warning + informational events.
    Set-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL" `
        -Name "EventLogging" -Value 7 -Type DWord -Force

    # Persist the KEM group list to the registry so GP refreshes can't revert it
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010003"
    if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
    Set-ItemProperty -Path $regBase -Name "Functions" -Value @(
        "x25519_mlkem768",
        "secp256r1_mlkem768",
        "secp384r1_mlkem1024",
        "NistP384",
        "NistP256",
        "x25519"
    ) -Type MultiString

    Write-Host "ML-KEM priority list:"
    Get-TlsEccCurve | Select-Object Name, Priority | Format-Table -AutoSize
}

Restart-VmAndWait -VmName $VmClient

# ---- Step 3: Force Group Policy (Root CA trust) + TLS verification ---------
Write-Step "Applying Group Policy and verifying PQC TLS from client..."

Invoke-InVmDomain -VmName $VmClient -ArgumentList $DomainName -ScriptBlock {
    param($DomainFqdn)

    function Log([string]$m) { Write-Host "[Verify $(Get-Date -Format HH:mm:ss)] $m" }

    # Apply Root CA trust from domain GPO
    Log "Running gpupdate to pull Root CA trust from domain..."
    gpupdate /force /wait:60 | Out-Null

    # Confirm Root CA is now in Trusted Root store
    Log "--- Trusted Root CAs (PQCLab entries) ---"
    Get-ChildItem cert:\LocalMachine\Root |
        Where-Object { $_.Subject -match "PQCLab" } |
        Select-Object Subject, Thumbprint,
            @{n="SigAlg";  e={$_.SignatureAlgorithm.FriendlyName}},
            @{n="Expires"; e={$_.NotAfter.ToString("yyyy-MM-dd")}} |
        Format-List

    # TLS handshake test via SslStream
    # NegotiatedCipherSuite shows the cipher; the KEM group is in Schannel event 36880
    Log "--- TLS Handshake Test → webserver01.$DomainFqdn:443 ---"
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient("webserver01.$DomainFqdn", 443)
        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(), $false,
            [System.Net.Security.RemoteCertificateValidationCallback]{ param($s,$c,$ch,$e) $true }
        )
        $ssl.AuthenticateAsClient("webserver01.$DomainFqdn")

        Write-Host "  TLS Protocol     : $($ssl.SslProtocol)"
        Write-Host "  Cipher Suite     : $($ssl.NegotiatedCipherSuite)"
        Write-Host "  Is Authenticated : $($ssl.IsAuthenticated)"
        Write-Host "  Is Encrypted     : $($ssl.IsEncrypted)"

        $serverCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $ssl.RemoteCertificate
        )
        Write-Host ""
        Write-Host "  Server Certificate:"
        Write-Host "    Subject    : $($serverCert.Subject)"
        Write-Host "    Issuer     : $($serverCert.Issuer)"
        Write-Host "    Valid Until: $($serverCert.NotAfter.ToString('yyyy-MM-dd'))"
        Write-Host "    Sig Alg    : $($serverCert.SignatureAlgorithm.FriendlyName)"
        Write-Host "    Thumbprint : $($serverCert.Thumbprint)"

        $ssl.Close(); $tcp.Close()
        Log "TLS handshake succeeded."
    } catch {
        Write-Warning "TLS handshake failed: $($_.Exception.Message)"
        Write-Host "  Check: web server reachable? Root CA trusted? Webserver cert enrolled?"
    }

    # Make a live HTTPS request so Schannel logs Event 36880
    Log "--- Live HTTPS Request ---"
    try {
        $r = Invoke-WebRequest -Uri "https://webserver01.$DomainFqdn" -UseBasicParsing -TimeoutSec 15
        Write-Host "  Status: $($r.StatusCode) $($r.StatusDescription)"
    } catch {
        Write-Warning "  Invoke-WebRequest: $($_.Exception.Message)"
    }

    # Read Schannel TLS establishment event (EventID 36880)
    Start-Sleep -Seconds 2
    Log "--- Schannel EventID 36880 (TLS Session Established) ---"
    $since = (Get-Date).AddMinutes(-15)
    $events = Get-WinEvent -FilterHashtable @{
        LogName      = "System"
        ProviderName = "Schannel"
        Id           = 36880
        StartTime    = $since
    } -ErrorAction SilentlyContinue

    if ($events) {
        $events | Select-Object -First 3 | ForEach-Object {
            Write-Host "  [$($_.TimeCreated.ToString('HH:mm:ss'))]"
            Write-Host "  $($_.Message)"
            Write-Host "  ---"
        }
    } else {
        Write-Host "  No EventID 36880 events yet. If the HTTPS request succeeded,"
        Write-Host "  try: Get-WinEvent -LogName System -Source Schannel manually."
    }

    # Summary
    Write-Host ""
    Write-Host "=== EXPECTED PQC TLS PROFILE ===" -ForegroundColor Green
    Write-Host "  Protocol  : TLS 1.3"
    Write-Host "  Cipher    : TLS_AES_256_GCM_SHA384"
    Write-Host "  Key Exch  : x25519_mlkem768  ← confirm in Edge F12 Security tab"
    Write-Host "  Cert Sig  : id-ML-DSA-65 (chain to id-ML-DSA-87 Root)"
    Write-Host ""
    Write-Host "=== BROWSER VERIFICATION (Edge DevTools) ===" -ForegroundColor Yellow
    Write-Host "  1. Open Microsoft Edge on the Win11 client VM"
    Write-Host "  2. Navigate to:  https://webserver01.$DomainFqdn"
    Write-Host "  3. Cert check:   padlock → Connection is secure → Certificate is valid"
    Write-Host "     Confirm: Subject   = CN=webserver01.$DomainFqdn"
    Write-Host "              Issuer    = PQCLab Issuing CA"
    Write-Host "              Sig Alg   = id-ML-DSA-65"
    Write-Host "  4. KEM check:    F12 → Security tab → Connection section"
    Write-Host "     Confirm: Key exchange = x25519_mlkem768"
    Write-Host "              Protocol    = TLS 1.3"
    Write-Host ""
    Write-Host "  If Key Exchange shows only ECDH or x25519 (no mlkem suffix):" -ForegroundColor Red
    Write-Host "    → ML-KEM was NOT negotiated. Verify both VMs were restarted after"
    Write-Host "      07-enable-mlkem-tls.ps1 ran, and that the Win11 Insider build"
    Write-Host "      is 26100.8514 or later."
}

Write-Step "Win11 client configuration complete."
Write-Host ""
Write-Host "Lab topology summary:" -ForegroundColor Cyan
Write-Host "  $VmRootCa      → Root CA           (ML-DSA-87, standalone, offline after setup)"
Write-Host "  $VmDc          → Domain Controller  ($DomainName)"
Write-Host "  $VmIssuingCa   → Issuing CA         (ML-DSA-65, domain member)"
Write-Host "  $VmWeb         → Web Server         (ML-DSA TLS cert + ML-KEM key exchange)"
Write-Host "  $VmClient      → Win11 Test Client  (ML-KEM enabled, Edge for PQC verification)"
