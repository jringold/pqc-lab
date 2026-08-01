. "$PSScriptRoot\00-variables.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Get-LocalAdminCredential {
    $secure = ConvertTo-SecureString $LocalAdminPasswordPlain -AsPlainText -Force
    return [pscredential]::new($LocalAdminUser, $secure)
}

function Get-DomainAdminCredential {
    $secure = ConvertTo-SecureString $LocalAdminPasswordPlain -AsPlainText -Force
    return [pscredential]::new("$DomainNetbios\$DomainAdminUser", $secure)
}

function Wait-VMReadyForDirect {
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [int]$TimeoutSeconds = 600
    )

    $started = Get-Date
    while ((Get-Date) -lt $started.AddSeconds($TimeoutSeconds)) {
        foreach ($cred in @((Get-LocalAdminCredential), (Get-DomainAdminCredential))) {
            try {
                $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop
                Remove-PSSession $s
                return
            } catch {
            }
        }
        Start-Sleep -Seconds 10
    }
    throw "Timed out waiting for PowerShell Direct on VM '$VmName'."
}

function Invoke-InVmLocal {
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $cred = Get-LocalAdminCredential
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Invoke-InVmDomain {
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $cred = Get-DomainAdminCredential
    Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Restart-VmAndWait {
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [int]$BootWaitSeconds = 60
    )
    Restart-VM -Name $VmName -Force | Out-Null
    Start-Sleep -Seconds $BootWaitSeconds
    Wait-VMReadyForDirect -VmName $VmName
}

function Ensure-Folder {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}
