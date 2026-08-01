# =============================================================================
# PQC PKI Lab — Azure: Patch Verification
# Checks all server VMs for the required KBs to support ML-DSA and ML-KEM TLS.
#
# Required KBs (GA mode — Server 2025 build 26100.x):
#   KB5099536  (July 14, 2026, OS Build 26100.33158)
#              Adds ML-KEM hybrid TLS to Schannel AND supersedes KB5087539.
#              This single KB satisfies both ML-DSA (CA) and ML-KEM (web/TLS).
#
#   KB5087539  (May 2026) — ML-DSA minimum for CA servers.
#              Sufficient for CA-only VMs if KB5099536 not yet applied,
#              but KB5099536 is preferred and covers both capabilities.
#
# vNext mode (build 29550+): All PQC features built-in — no KBs needed.
#
# Run after 01-deploy-infrastructure.ps1 and before 02-config-dc.ps1.
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"

# --- Patch check script block (executed on each VM via az vm run-command) ----
$checkScript = @'
$build    = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
$revision = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
$caption  = (Get-WmiObject Win32_OperatingSystem).Caption
$fullBuild = "$build.$revision"

Write-Host "========================================"
Write-Host "OS    : $caption"
Write-Host "Build : $fullBuild"
Write-Host "========================================"

# vNext (29550+): all PQC features built-in
if ($build -ge 29550) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    Write-Host "vNext $fullBuild — ML-DSA and ML-KEM built-in (no KBs needed)."
    exit 0
}

# Must be Server 2025 GA (26100.x)
if ($build -ne 26100) {
    Write-Host "STATUS: FAIL" -ForegroundColor Red
    Write-Host "Unsupported build $fullBuild. Requires Server 2025 (26100.x) or vNext (29550+)."
    exit 2
}

# Build revision >= 33158 means KB5099536 is applied (July 14, 2026 CU)
if ($revision -ge 33158) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    Write-Host "KB5099536 confirmed via build ($fullBuild >= 26100.33158)"
    Write-Host "  ML-DSA certificate issuance : Supported"
    Write-Host "  ML-KEM hybrid TLS           : Supported"
    exit 0
}

# Fallback: check hotfix list (handles out-of-band installs)
$hotfixes   = Get-HotFix | Select-Object -ExpandProperty HotFixID
$has5099536 = $hotfixes -contains "KB5099536"
$has5087539 = $hotfixes -contains "KB5087539"

if ($has5099536) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    Write-Host "KB5099536 found in hotfix list (build $fullBuild)"
    Write-Host "  ML-DSA certificate issuance : Supported"
    Write-Host "  ML-KEM hybrid TLS           : Supported"
    exit 0
}

if ($has5087539) {
    Write-Host "STATUS: WARN" -ForegroundColor Yellow
    Write-Host "KB5087539 found but KB5099536 not yet applied (build $fullBuild)"
    Write-Host "  ML-DSA certificate issuance : Supported"
    Write-Host "  ML-KEM hybrid TLS           : NOT Supported"
    Write-Host "  ACTION: Install KB5099536 to enable ML-KEM TLS."
    Write-Host "          https://support.microsoft.com/kb/5099536"
    exit 1
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
Write-Host "No PQC KBs detected on build $fullBuild"
Write-Host "  ML-DSA certificate issuance : NOT Supported"
Write-Host "  ML-KEM hybrid TLS           : NOT Supported"
Write-Host "  ACTION: Run Windows Update until KB5099536 (build 26100.33158) is applied,"
Write-Host "          or download it from: https://support.microsoft.com/kb/5099536"
exit 2
'@

# --- VMs to verify (server VMs only; Win11 client checked separately) --------
$serverVMs = @($VM_ROOTCA, $VM_DC, $VM_ISSUINGCA, $VM_WEBSERVER)

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== PQC Patch Verification ===" -ForegroundColor Cyan
Write-Host "    Deployment mode : $DEPLOYMENT_MODE"
Write-Host "    Resource group  : $RESOURCE_GROUP"
Write-Host "    VMs to check    : $($serverVMs -join ', ')"
Write-Host ""

if ($DEPLOYMENT_MODE -eq "vNext") {
    Write-Host "Deployment mode is vNext — PQC features are built-in." -ForegroundColor Cyan
    Write-Host "Verification will confirm the OS build number on each VM."
    Write-Host ""
}

$overallPassed = $true
$summary = @()

foreach ($vmName in $serverVMs) {
    Write-Host "--- Checking: $vmName ---" -ForegroundColor Cyan

    # Ensure VM is running before invoking run-command
    $vmState = az vm show --resource-group $RESOURCE_GROUP --name $vmName --query "powerState" -o tsv 2>$null
    if ($vmState -notlike "*running*") {
        Write-Warning "  VM '$vmName' is not in a running state ($vmState). Skipping."
        $summary += [PSCustomObject]@{ VM = $vmName; Status = "SKIPPED"; Notes = "VM not running ($vmState)" }
        $overallPassed = $false
        continue
    }

    $result = az vm run-command invoke `
        --resource-group $RESOURCE_GROUP `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts $checkScript `
        --output json 2>$null | ConvertFrom-Json

    if ($result -and $result.value) {
        $stdout = ($result.value | Where-Object { $_.code -match "StdOut" } |
                   Select-Object -ExpandProperty message) -join ""
        $stderr = ($result.value | Where-Object { $_.code -match "StdErr" } |
                   Select-Object -ExpandProperty message) -join ""

        Write-Host $stdout
        if ($stderr -and $stderr.Trim()) { Write-Warning $stderr }

        if ($stdout -match "STATUS: PASS")  { $status = "PASS"    }
        elseif ($stdout -match "STATUS: WARN") { $status = "WARN"; $overallPassed = $false }
        else                                { $status = "FAIL"; $overallPassed = $false }
    } else {
        Write-Warning "  Could not retrieve result — VM may still be booting. Retry in 60 seconds."
        $status = "ERROR"
        $overallPassed = $false
    }

    $summary += [PSCustomObject]@{ VM = $vmName; Status = $status; Notes = "" }
    Write-Host ""
}

# --- Summary table -----------------------------------------------------------
Write-Host "=== Summary ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize
Write-Host ""

if ($overallPassed) {
    Write-Host "All server VMs passed patch verification." -ForegroundColor Green
    Write-Host "Proceed to: 02-config-dc.ps1"
} else {
    Write-Host "One or more VMs require attention before continuing." -ForegroundColor Yellow
    Write-Host "Install KB5099536 on flagged VMs, then re-run this script."
    Write-Host "KB5099536 download: https://support.microsoft.com/kb/5099536"
}
