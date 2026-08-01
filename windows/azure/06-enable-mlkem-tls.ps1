# =============================================================================
# PQC PKI Lab — Phase 7: Enable ML-KEM Hybrid TLS Key Exchange
# Enables x25519_mlkem768 (and optionally secp256r1_mlkem768) on both the
# Web Server and all client machines.
#
# ML-KEM is the key EXCHANGE in the TLS 1.3 handshake — it is independent of
# the certificate's signature algorithm (ML-DSA). Both must be enabled for
# a fully post-quantum-safe TLS session.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"
az account set --subscription $SUBSCRIPTION_ID

$mlkemScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"

function Log([string]`$msg) { Write-Host "[ML-KEM `$(Get-Date -Format HH:mm:ss)] `$msg" }

# --- Method 1: PowerShell TLS cmdlets (vNext 29550+ only) ---
Log "Checking current TLS ECC/KEM curves..."
Get-TlsEccCurve | Select-Object Name, Priority | Format-Table

Log "Enabling x25519_mlkem768 hybrid group..."
Enable-TlsEccCurve -Name "x25519_mlkem768"

Log "Enabling secp256r1_mlkem768 hybrid group..."
Enable-TlsEccCurve -Name "secp256r1_mlkem768"

Log "Enabling secp384r1_mlkem1024 hybrid group..."
Enable-TlsEccCurve -Name "secp384r1_mlkem1024"

# Set priority order: ML-KEM hybrids first, then classical fallbacks
# This ensures ML-KEM is negotiated when both sides support it
Log "Setting KEM group priority order..."
Set-TlsEccCurve -Name @(
    "x25519_mlkem768",        # Recommended: best performance hybrid (NIST Level 1 + X25519)
    "secp256r1_mlkem768",     # Alternative: NIST P-256 + ML-KEM-768
    "secp384r1_mlkem1024",    # High-security: NIST P-384 + ML-KEM-1024
    "NistP384",               # Classical fallback for non-PQC clients
    "NistP256",               # Classical fallback
    "x25519"                  # Classical fallback
)

# --- Method 2: Group Policy registry path (alternative / persistent) ---
Log "Setting registry keys for persistence (survives GP refresh)..."

`$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010003"
if (-not (Test-Path `$regBase)) { New-Item -Path `$regBase -Force | Out-Null }

Set-ItemProperty -Path `$regBase -Name "Functions" -Value (
    "x25519_mlkem768\0" +
    "secp256r1_mlkem768\0" +
    "secp384r1_mlkem1024\0" +
    "NistP384\0" +
    "NistP256\0" +
    "x25519"
) -Type String

# Ensure TLS 1.3 is enabled (required for ML-KEM)
Log "Verifying TLS 1.3 is enabled..."
`$tls13Key = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server"
if (-not (Test-Path `$tls13Key)) { New-Item -Path `$tls13Key -Force | Out-Null }
Set-ItemProperty -Path `$tls13Key -Name "Enabled" -Value 1 -Type DWord
Set-ItemProperty -Path `$tls13Key -Name "DisabledByDefault" -Value 0 -Type DWord

`$tls13ClientKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Client"
if (-not (Test-Path `$tls13ClientKey)) { New-Item -Path `$tls13ClientKey -Force | Out-Null }
Set-ItemProperty -Path `$tls13ClientKey -Name "Enabled" -Value 1 -Type DWord
Set-ItemProperty -Path `$tls13ClientKey -Name "DisabledByDefault" -Value 0 -Type DWord

Log "TLS 1.3 enabled."

# Confirm final state
Log "Final TLS ECC/KEM curve list:"
Get-TlsEccCurve | Select-Object Name, Priority | Format-Table

Log "=== ML-KEM hybrid TLS groups enabled. Restart required. ==="
Restart-Computer -Force
"@

# Enable on Web Server (the TLS server side)
Write-Host "=== Enabling ML-KEM on Web Server ===" -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_WEBSERVER `
    --command-id RunPowerShellScript `
    --scripts $mlkemScript

Write-Host "Web server restarting after ML-KEM configuration..."
Start-Sleep -Seconds 60

# Also enable on Domain Controller (it may serve LDAPS/TLS)
Write-Host "=== Enabling ML-KEM on Domain Controller ===" -ForegroundColor Cyan
az vm run-command invoke `
    --resource-group $RESOURCE_GROUP `
    --name $VM_DC `
    --command-id RunPowerShellScript `
    --scripts $mlkemScript

Write-Host ""
Write-Host "=== ML-KEM TLS configuration complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "NOTE: To test ML-KEM from a Windows 11 client:"
Write-Host "  1. Client must be Win 11 24H2/25H2 + KB5087036 or later"
Write-Host "  2. Run the same Enable-TlsEccCurve commands on the client"
Write-Host "  3. Use Microsoft Edge (CNG-based) for browser testing"
Write-Host "  4. Verify with: Test-NetConnection -ComputerName webserver01.pqclab.local -Port 443"
Write-Host ""
Write-Host "Next step: run 07-verify.ps1"
