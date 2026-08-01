# =============================================================================
# PQC PKI Lab — Hyper-V: Patch Verification
# Checks all server VMs for the required KBs via PowerShell Direct.
#
# Required KBs (GA mode — Server 2025 build 26100.x):
#   KB5099536  (July 14, 2026, OS Build 26100.33158)
#              Adds ML-KEM hybrid TLS AND supersedes KB5087539.
#              Satisfies both ML-DSA (CA) and ML-KEM (TLS) requirements.
#
#   KB5087539  (May 2026) — ML-DSA minimum for CA servers only.
#              Sufficient for CA-only VMs if KB5099536 is not yet applied,
#              but KB5099536 is preferred and covers both capabilities.
#
# vNext mode (build 29550+): All PQC features built-in — no KBs needed.
#
# Run after 02-new-lab-vms.ps1 and before 03-config-dc.ps1.
# Requires Hyper-V PowerShell Direct (VMs must be running, no network needed).
# =============================================================================

. "$PSScriptRoot\00-variables.ps1"

# --- Patch check script block (runs inside each VM via PowerShell Direct) ----
$checkBlock = {
    $build    = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    $revision = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
    $caption  = (Get-WmiObject Win32_OperatingSystem).Caption
    $fullBuild = "$build.$revision"

    $result = [PSCustomObject]@{
        OS        = $caption
        Build     = $fullBuild
        MLDSA     = $false
        MLKEM     = $false
        Status    = "FAIL"
        Notes     = ""
    }

    # vNext (29550+): all PQC features built-in
    if ($build -ge 29550) {
        $result.MLDSA  = $true
        $result.MLKEM  = $true
        $result.Status = "PASS"
        $result.Notes  = "vNext $fullBuild — all PQC features built-in"
        return $result
    }

    # Must be Server 2025 GA (26100.x)
    if ($build -ne 26100) {
        $result.Status = "FAIL"
        $result.Notes  = "Unsupported build. Need 26100.x (Server 2025) or 29550+ (vNext)."
        return $result
    }

    # Build revision >= 33158 = KB5099536 (July 14, 2026)
    if ($revision -ge 33158) {
        $result.MLDSA  = $true
        $result.MLKEM  = $true
        $result.Status = "PASS"
        $result.Notes  = "KB5099536 confirmed via build ($fullBuild >= 26100.33158)"
        return $result
    }

    # Fallback: check hotfix list
    $hotfixes   = Get-HotFix | Select-Object -ExpandProperty HotFixID
    $has5099536 = $hotfixes -contains "KB5099536"
    $has5087539 = $hotfixes -contains "KB5087539"

    if ($has5099536) {
        $result.MLDSA  = $true
        $result.MLKEM  = $true
        $result.Status = "PASS"
        $result.Notes  = "KB5099536 in hotfix list (build $fullBuild)"
    } elseif ($has5087539) {
        $result.MLDSA  = $true
        $result.MLKEM  = $false
        $result.Status = "WARN"
        $result.Notes  = "KB5087539 present; KB5099536 missing — ML-KEM TLS not enabled"
    } else {
        $result.Status = "FAIL"
        $result.Notes  = "No PQC KBs detected on $fullBuild — install KB5099536"
    }

    return $result
}

# ---------------------------------------------------------------------------
$serverVMs  = @($VmDc, $VmRootCa, $VmIssuingCa, $VmWeb)
$vmCred     = Get-Credential -UserName $LocalAdminUser `
              -Message "Enter the local administrator password for the lab VMs"

Write-Host ""
Write-Host "=== PQC Patch Verification (Hyper-V) ===" -ForegroundColor Cyan
Write-Host "    Deployment mode : $DeploymentMode"
Write-Host "    VMs to check    : $($serverVMs -join ', ')"
Write-Host ""

if ($DeploymentMode -eq "vNext") {
    Write-Host "Deployment mode is vNext — PQC features are built-in." -ForegroundColor Cyan
    Write-Host "Verification will confirm the OS build number on each VM."
    Write-Host ""
}

$report       = @()
$overallPassed = $true

foreach ($vmName in $serverVMs) {
    Write-Host "  Checking: $vmName ..." -NoNewline

    # Confirm VM is running
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne "Running") {
        Write-Host " SKIPPED (VM not running)" -ForegroundColor Yellow
        $report += [PSCustomObject]@{
            VM = $vmName; OS = "N/A"; Build = "N/A"
            "ML-DSA" = "⚠"; "ML-KEM" = "⚠"
            Status = "SKIPPED"; Notes = "VM not running"
        }
        $overallPassed = $false
        continue
    }

    try {
        $r = Invoke-Command -VMName $vmName -Credential $vmCred `
             -ScriptBlock $checkBlock -ErrorAction Stop

        $mldsa  = if ($r.MLDSA) { "✅" } else { "❌" }
        $mlkem  = if ($r.MLKEM) { "✅" } else { "❌" }
        $color  = switch ($r.Status) {
            "PASS" { "Green"  }
            "WARN" { "Yellow" }
            default { "Red"   }
        }

        Write-Host " $($r.Status)  $($r.Notes)" -ForegroundColor $color

        $report += [PSCustomObject]@{
            VM = $vmName; OS = $r.OS; Build = $r.Build
            "ML-DSA" = $mldsa; "ML-KEM" = $mlkem
            Status = $r.Status; Notes = $r.Notes
        }

        if ($r.Status -ne "PASS") { $overallPassed = $false }

    } catch {
        Write-Host " ERROR — $_" -ForegroundColor Red
        $report += [PSCustomObject]@{
            VM = $vmName; OS = "N/A"; Build = "N/A"
            "ML-DSA" = "❌"; "ML-KEM" = "❌"
            Status = "ERROR"; Notes = $_.Exception.Message
        }
        $overallPassed = $false
    }
}

# --- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$report | Format-Table VM, Build, "ML-DSA", "ML-KEM", Status, Notes -AutoSize
Write-Host ""

if ($overallPassed) {
    Write-Host "All server VMs passed patch verification." -ForegroundColor Green
    Write-Host "Proceed to: 03-config-dc.ps1"
} else {
    Write-Host "One or more VMs require attention before continuing." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To apply KB5099536 on a WARN/FAIL VM via PowerShell Direct:"
    Write-Host '  $s = New-PSSession -VMName <vmName> -Credential $vmCred'
    Write-Host '  Invoke-Command -Session $s -ScriptBlock { Install-WindowsUpdate -KBArticleID "KB5099536" -AcceptAll -AutoReboot }'
    Write-Host "  (Requires PSWindowsUpdate module, or download from https://support.microsoft.com/kb/5099536)"
}
