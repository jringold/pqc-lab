#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Provision Hyper-V VMs for PQ CA testing (CA, Web, Client).

.DESCRIPTION
  Creates three Ubuntu VMs from a prepared Ubuntu 26.04 template VHDX, starts
  them, discovers their IPv4 addresses via Hyper-V integration services, and
  writes a Bash-compatible .deploy-state file for 00-remote-deploy.sh.

.NOTES
  Requires:
    - Hyper-V feature enabled
    - A prepared Ubuntu 26.04 template VHDX with SSH enabled
    - A reachable user account + SSH key in that template
#>

param(
  [string]$Prefix = "pq-hv",
  [string]$VmRoot = "C:\HyperV\pq-ca",
  [string]$BaseVhdx,
  [string]$SwitchName = "Default Switch",
  [string]$ExternalAdapterName = "",
  [string]$AdminUser = "azureuser",
  [string]$Provider = "liboqs",
  [int]$CpuCount = 4,
  [int]$MemoryGB = 8,
  [int]$BootTimeoutSec = 900
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
  Write-Host "[ERROR] $Message" -ForegroundColor Red
  exit 1
}

function Info($Message) {
  Write-Host "[INFO]  $Message" -ForegroundColor Cyan
}

function Ok($Message) {
  Write-Host "[OK]    $Message" -ForegroundColor Green
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
  Fail "Hyper-V PowerShell module not found. Enable Hyper-V first."
}

Import-Module Hyper-V

if ([string]::IsNullOrWhiteSpace($BaseVhdx)) {
  Fail "You must pass -BaseVhdx, for example: -BaseVhdx C:\HyperV\BaseImages\ubuntu-26.04-template.vhdx"
}
if (-not (Test-Path $BaseVhdx)) {
  Fail "Base VHDX not found: $BaseVhdx"
}
if ($Provider -notin @("liboqs", "symcrypt")) {
  Fail "Provider must be liboqs or symcrypt."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
  if ([string]::IsNullOrWhiteSpace($ExternalAdapterName)) {
    Fail "VMSwitch '$SwitchName' not found. Provide -ExternalAdapterName to create one."
  }
  Info "Creating external VMSwitch '$SwitchName' on adapter '$ExternalAdapterName'..."
  New-VMSwitch -Name $SwitchName -NetAdapterName $ExternalAdapterName -AllowManagementOS $true | Out-Null
  Ok "VMSwitch created."
}

$memoryBytes = $MemoryGB * 1GB
$statePath = Join-Path $PSScriptRoot ".deploy-state"

$defs = @(
  @{ Role = "ca";     Name = "${Prefix}-ca-vm" },
  @{ Role = "web";    Name = "${Prefix}-web-vm" },
  @{ Role = "client"; Name = "${Prefix}-client-vm" }
)

New-Item -ItemType Directory -Force -Path $VmRoot | Out-Null

foreach ($vm in $defs) {
  $name = $vm.Name
  $vmDir = Join-Path $VmRoot $name
  $disk = Join-Path $vmDir "$name.vhdx"

  if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
    Info "VM exists, ensuring it's running: $name"
    Start-VM -Name $name | Out-Null
    continue
  }

  New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
  Info "Creating differencing disk for $name"
  New-VHD -Path $disk -ParentPath $BaseVhdx -Differencing | Out-Null

  Info "Creating VM $name"
  New-VM `
    -Name $name `
    -Generation 2 `
    -MemoryStartupBytes $memoryBytes `
    -VHDPath $disk `
    -Path $vmDir `
    -SwitchName $SwitchName | Out-Null

  Set-VMProcessor -VMName $name -Count $CpuCount
  Set-VM -VMName $name -AutomaticCheckpointsEnabled $false | Out-Null
  Start-VM -Name $name | Out-Null
}

function Get-IPv4Address($VmName) {
  $adapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
  if (-not $adapter) { return $null }
  $ips = $adapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' }
  return ($ips | Select-Object -First 1)
}

$deadline = (Get-Date).AddSeconds($BootTimeoutSec)
$ips = @{}

foreach ($vm in $defs) {
  $name = $vm.Name
  Info "Waiting for IPv4 on $name ..."
  do {
    $ip = Get-IPv4Address -VmName $name
    if ($ip) {
      $ips[$vm.Role] = $ip
      Ok "$name IP: $ip"
      break
    }
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)

  if (-not $ips.ContainsKey($vm.Role)) {
    Fail "Timed out waiting for IP on $name. Confirm guest booted and has network."
  }
}

$state = @"
CA_IP=$($ips["ca"])
WEB_IP=$($ips["web"])
CLIENT_IP=$($ips["client"])
ADMIN_USER=$AdminUser
PREFIX=$Prefix
PROVIDER=$Provider
HYPERV_SWITCH=$SwitchName
VM_ROOT=$VmRoot
"@

Set-Content -Path $statePath -Value $state -NoNewline

Write-Host ""
Write-Host "============================================================"
Write-Host "  HYPER-V PROVISIONING COMPLETE"
Write-Host "============================================================"
Write-Host "  CA VM    : ssh $AdminUser@$($ips["ca"])"
Write-Host "  Web VM   : ssh $AdminUser@$($ips["web"])"
Write-Host "  Client VM: ssh $AdminUser@$($ips["client"])"
Write-Host "  Provider : $Provider"
Write-Host ""
Write-Host "  State file written: $statePath"
Write-Host "  Next step:"
Write-Host "    bash ./00-remote-deploy.sh"
Write-Host "============================================================"
