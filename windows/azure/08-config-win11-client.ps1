# =============================================================================
# PQC PKI Lab — Phase 10: Configure Windows 11 Insider Preview Client
# Domain-joins the Win11 client VM, enables ML-KEM TLS groups, forces Root CA
# trust via Group Policy, and runs an automated TLS verification test.
#
# Prerequisites:
#   - Scripts 01 through 07 must be complete.
#   - Win11 client VM must have been deployed (added by 01-deploy-infrastructure.ps1).
#   - Win11 ISO (GA 24H2 + KB5101650, build 26100.8524+, or Insider Preview 26100.8514+)
#     must have been uploaded to the Compute Gallery as image definition $WIN11_IMAGE_DEF_NAME
#     (same process as the Server vNext image — see 00-prepare-image.ps1 comments).
#
# Why a separate Win11 client?
#   - Verifies ML-KEM key exchange from the CLIENT side (server enabling alone is
#     not sufficient; both endpoints must advertise ML-KEM support groups).
#   - Provides an isolated test machine with Microsoft Edge for browser-level
#     PQC TLS inspection via F12 DevTools → Security tab.
#
# Win11 ML-KEM build requirements (as of July 14, 2026 security updates):
#   - Win11 24H2 / 25H2 GA:  KB5089573 (preview, build 26100.8524+) or KB5101650 (production)
#   - Win11 26H1 GA:         KB5095091 or later
#   - Win11 Insider Preview: build 26100.8514+ (still valid, predates GA enablement)
#   Insider Preview is NO LONGER REQUIRED — GA Win11 24H2 with KB5101650 is sufficient.
#
# Server ML-KEM (TLS key exchange only):
#   - Windows Server 2025 GA + KB5099536 (July 14, 2026) — same cmdlets, same groups
#   - Windows Server vNext 29550+ — still valid single-image path
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

# =============================================================================
# Step 1: Domain join the Win11 client and set DNS
# =============================================================================
Write-Host "=== Step 1: Domain Join Windows 11 Client ===" -ForegroundColor Cyan

$domainJoinScript = @"
`$ErrorActionPreference = "Stop"
function Log([string]`$m) { Write-Host "[DomainJoin `$(Get-Date -Format HH:mm:ss)] `$m" }

# Point DNS to the domain controller
`$nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
if (-not `$nic) { throw "No active NIC found." }
Set-DnsClientServerAddress -InterfaceIndex `$nic.ifIndex -ServerAddresses @("$DC_IP")
Log "DNS set to DC at $DC_IP"

# Rename the machine before domain join so it gets a clean AD record
if (`$env:COMPUTERNAME -ne "win11client") {
    Rename-Computer -NewName "win11client" -Force
    Log "Renamed to win11client"
}

# Join domain
`$secure = ConvertTo-SecureString "$ADMIN_PASS" -AsPlainText -Force
`$cred   = [pscredential]::new("$DOMAIN_NETBIOS\$ADMIN_USER", `$secure)
Add-Computer -DomainName "$DOMAIN_NAME" -Credential `$cred -Force
Log "Domain join requested — restarting..."
Restart-Computer -Force
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_CLIENT `
    --command-id RunPowerShellScript `
    --scripts $domainJoinScript

Write-Host "Waiting 90 s for Win11 client to restart after domain join..."
Start-Sleep -Seconds 90

# =============================================================================
# Step 2: Enable ML-KEM hybrid TLS groups (client side)
# =============================================================================
Write-Host "=== Step 2: Enable ML-KEM TLS Groups on Win11 Client ===" -ForegroundColor Cyan

# NOTE: As of July 14, 2026 (KB5101650), GA Win11 24H2/25H2 supports the same
# Enable-TlsEccCurve / Set-TlsEccCurve cmdlets. Insider Preview no longer required.
$mlkemClientScript = @"
`$ErrorActionPreference = "Stop"
function Log([string]`$m) { Write-Host "[ML-KEM-Client `$(Get-Date -Format HH:mm:ss)] `$m" }

Log "Enabling ML-KEM hybrid key-exchange groups..."
Enable-TlsEccCurve -Name "x25519_mlkem768"
Enable-TlsEccCurve -Name "secp256r1_mlkem768"
Enable-TlsEccCurve -Name "secp384r1_mlkem1024"

# Prioritise ML-KEM hybrids so the client advertises them first in ClientHello
Set-TlsEccCurve -Name @(
    "x25519_mlkem768",
    "secp256r1_mlkem768",
    "secp384r1_mlkem1024",
    "NistP384",
    "NistP256",
    "x25519"
)

# Ensure TLS 1.3 Client is explicitly enabled (ML-KEM is TLS 1.3-only)
`$clientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
if (-not (Test-Path `$clientKey)) { New-Item -Path `$clientKey -Force | Out-Null }
Set-ItemProperty -Path `$clientKey -Name "Enabled"          -Value 1 -Type DWord
Set-ItemProperty -Path `$clientKey -Name "DisabledByDefault" -Value 0 -Type DWord

# Enable Schannel verbose event logging so TLS negotiation details appear in
# the System event log (Event ID 36880 = TLS session established).
# Level 7 = log errors + warnings + informational SChannel events.
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL" `
    -Name "EventLogging" -Value 7 -Type DWord -Force

# Persist KEM group list to registry for resilience across policy refreshes
`$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010003"
if (-not (Test-Path `$regBase)) { New-Item -Path `$regBase -Force | Out-Null }
Set-ItemProperty -Path `$regBase -Name "Functions" -Value @(
    "x25519_mlkem768",
    "secp256r1_mlkem768",
    "secp384r1_mlkem1024",
    "NistP384",
    "NistP256",
    "x25519"
) -Type MultiString

Log "Configured KEM priority:"
Get-TlsEccCurve | Select-Object Name, Priority | Format-Table -AutoSize

Log "ML-KEM enabled — restarting to apply all settings..."
Restart-Computer -Force
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_CLIENT `
    --command-id RunPowerShellScript `
    --scripts $mlkemClientScript

Write-Host "Waiting 90 s for Win11 client to restart after ML-KEM configuration..."
Start-Sleep -Seconds 90

# =============================================================================
# Step 3: Apply Group Policy (Root CA trust) + Run TLS verification
# =============================================================================
Write-Host "=== Step 3: Apply Root CA Trust and Verify PQC TLS ===" -ForegroundColor Cyan

$verifyScript = @"
`$ErrorActionPreference = "SilentlyContinue"
function Log([string]`$m) { Write-Host "[Verify `$(Get-Date -Format HH:mm:ss)] `$m" }

# ---- 3a. Force Group Policy — imports Root CA cert from the domain GPO ------
Log "Forcing Group Policy update (applies Root CA trust distribution)..."
gpupdate /force /wait:60 | Out-Null
Log "Group Policy update complete."

# ---- 3b. Confirm Root CA is now in Trusted Root store ----------------------
Log "--- Trusted Root CAs (PQCLab entries) ---"
Get-ChildItem cert:\LocalMachine\Root |
    Where-Object { `$_.Subject -match "PQCLab" } |
    Select-Object Subject, Thumbprint,
        @{n="SigAlg";  e={`$_.SignatureAlgorithm.FriendlyName}},
        @{n="Expires"; e={`$_.NotAfter.ToString("yyyy-MM-dd")}} |
    Format-List

# ---- 3c. TLS handshake test using SslStream --------------------------------
Log "--- TLS Handshake Test → webserver01.$DOMAIN_NAME:443 ---"
try {
    `$tcp = New-Object System.Net.Sockets.TcpClient("webserver01.$DOMAIN_NAME", 443)
    `$ssl = New-Object System.Net.Security.SslStream(`$tcp.GetStream(), `$false, {param(`$s,`$c,`$ch,`$e) `$true})
    `$ssl.AuthenticateAsClient("webserver01.$DOMAIN_NAME")

    Write-Host "  TLS Protocol       : `$(`$ssl.SslProtocol)"
    Write-Host "  Cipher Suite       : `$(`$ssl.NegotiatedCipherSuite)"
    Write-Host "  Is Authenticated   : `$(`$ssl.IsAuthenticated)"
    Write-Host "  Is Encrypted       : `$(`$ssl.IsEncrypted)"

    # Extract and inspect the server certificate
    `$serverCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(`$ssl.RemoteCertificate)
    Write-Host ""
    Write-Host "  Server Certificate:"
    Write-Host "    Subject    : `$(`$serverCert.Subject)"
    Write-Host "    Issuer     : `$(`$serverCert.Issuer)"
    Write-Host "    Valid Until: `$(`$serverCert.NotAfter.ToString('yyyy-MM-dd'))"
    Write-Host "    Signature  : `$(`$serverCert.SignatureAlgorithm.FriendlyName)"
    Write-Host "    Thumbprint : `$(`$serverCert.Thumbprint)"

    `$ssl.Close(); `$tcp.Close()
    Write-Host ""
    Log "TLS handshake succeeded."
} catch {
    Write-Warning "TLS connection failed: `$(`$_.Exception.Message)"
    Write-Host "  Possible causes:"
    Write-Host "    - Root CA trust not yet applied (wait 2 min and re-run)"
    Write-Host "    - Web server not reachable (check NSG / VNet DNS)"
    Write-Host "    - Web server TLS binding not configured (re-run 05-config-webserver.ps1)"
}

# ---- 3d. Check Schannel event log for TLS negotiation details --------------
Log "--- Schannel TLS Events (last 10 min, EventID 36880) ---"
`$since = (Get-Date).AddMinutes(-10)
`$events = Get-WinEvent -FilterHashtable @{
    LogName      = "System"
    ProviderName = "Schannel"
    Id           = 36880
    StartTime    = `$since
} -ErrorAction SilentlyContinue

if (`$events) {
    `$events | Select-Object -First 5 | ForEach-Object {
        Write-Host "  [`$(`$_.TimeCreated.ToString('HH:mm:ss'))] `$(`$_.Message)" -Separator "`n"
        Write-Host "  ---"
    }
} else {
    Write-Host "  No EventID 36880 events found yet — make an HTTPS request to populate."
}

# ---- 3e. Quick HTTPS request to populate the event log -------------------
Log "--- HTTPS Request (populates Schannel event log) ---"
try {
    `$resp = Invoke-WebRequest -Uri "https://webserver01.$DOMAIN_NAME" -UseBasicParsing -TimeoutSec 15
    Write-Host "  HTTP Status: `$(`$resp.StatusCode) `$(`$resp.StatusDescription)"
} catch {
    Write-Warning "  HTTPS request: `$(`$_.Exception.Message)"
}

# Read events again after the request
Start-Sleep -Seconds 2
`$newEvents = Get-WinEvent -FilterHashtable @{
    LogName      = "System"
    ProviderName = "Schannel"
    Id           = 36880
    StartTime    = `$since
} -ErrorAction SilentlyContinue
if (`$newEvents -and `$newEvents.Count -gt (`$events.Count)) {
    Write-Host "  New Schannel TLS event recorded:"
    `$newEvents | Select-Object -First 1 | ForEach-Object { Write-Host "  `$(`$_.Message)" }
}

# ---- Summary ----------------------------------------------------------------
Log ""
Log "=== EXPECTED PQC TLS PROFILE ==="
Log "  TLS Protocol : TLS 1.3 (required for ML-KEM)"
Log "  Cipher Suite : TLS_AES_256_GCM_SHA384"
Log "  Key Exchange : x25519_mlkem768 (visible in Edge DevTools Security tab)"
Log "  Cert Sig Alg : id-ML-DSA-65 (chain to id-ML-DSA-87 Root)"
Log ""
Log "=== MANUAL BROWSER VERIFICATION (Edge DevTools) ==="
Log "  1. Open Microsoft Edge on this client VM"
Log "  2. Browse to:  https://webserver01.$DOMAIN_NAME"
Log "  3. Certificate: click padlock → Connection is secure → Certificate is valid"
Log "     Confirm: Subject = CN=webserver01.$DOMAIN_NAME"
Log "              Issuer  = PQCLab Issuing CA"
Log "              Sig Alg = id-ML-DSA-65"
Log "  4. Key Exchange: press F12 → Security tab → Connection section"
Log "     Confirm: Key exchange: x25519_mlkem768"
Log "              Protocol: TLS 1.3"
Log "  5. If Key Exchange shows ECDH or X25519 (no mlkem suffix):"
Log "     → ML-KEM was not negotiated. Re-check that ML-KEM is enabled on the"
Log "       server side (re-run 06-enable-mlkem-tls.ps1) and that both VMs"
Log "       have been restarted after the configuration change."
"@

az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_CLIENT `
    --command-id RunPowerShellScript `
    --scripts $verifyScript

# =============================================================================
# Final output
# =============================================================================
Write-Host ""
Write-Host "=== WIN11 CLIENT READY FOR PQC TLS TESTING ===" -ForegroundColor Green
Write-Host ""

$clientPip = az network public-ip show `
    --resource-group $RESOURCE_GROUP `
    --name "$VM_CLIENT-pip" `
    --query "ipAddress" -o tsv

Write-Host "Connect via RDP:" -ForegroundColor Cyan
Write-Host "  Host : $clientPip"
Write-Host "  User : $DOMAIN_NETBIOS\$ADMIN_USER"
Write-Host ""
Write-Host "Then in Edge on the client VM:" -ForegroundColor Cyan
Write-Host "  URL  : https://webserver01.$DOMAIN_NAME"
Write-Host "  F12 → Security → Key exchange should show: x25519_mlkem768"
Write-Host ""
Write-Host "The full lab is now:" -ForegroundColor Cyan
Write-Host "  $VM_ROOTCA     → Offline Root CA   (ML-DSA-87, standalone)"
Write-Host "  $VM_DC         → Domain Controller  (pqclab.local)"
Write-Host "  $VM_ISSUINGCA  → Issuing CA         (ML-DSA-65, domain member)"
Write-Host "  $VM_WEBSERVER  → Web Server         (ML-DSA-65 TLS cert, IIS)"
Write-Host "  $VM_CLIENT     → Win11 Test Client  (ML-KEM enabled, Edge for PQC verification)"
