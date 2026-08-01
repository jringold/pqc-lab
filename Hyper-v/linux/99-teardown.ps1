#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Remove Hyper-V PQ test VMs and optionally their switch.
#>

param(
  [string]$Prefix = "pq-hv",
  [string]$VmRoot = "C:\HyperV\pq-ca",
  [switch]$RemoveSwitch
)

$ErrorActionPreference = "Stop"

Import-Module Hyper-V

$statePath = Join-Path $PSScriptRoot ".deploy-state"
$switchName = $null

if (Test-Path $statePath) {
  $state = Get-Content $statePath
  foreach ($line in $state) {
    if ($line -like "HYPERV_SWITCH=*") { $switchName = $line.Split("=")[1] }
    if ($line -like "PREFIX=*") { $Prefix = $line.Split("=")[1] }
    if ($line -like "VM_ROOT=*") { $VmRoot = $line.Split("=")[1] }
  }
}

$names = @("${Prefix}-ca-vm", "${Prefix}-web-vm", "${Prefix}-client-vm")

Write-Host "This will delete VMs: $($names -join ', ')" -ForegroundColor Yellow
Write-Host "Press Ctrl+C within 10 seconds to cancel..."
Start-Sleep -Seconds 10

foreach ($name in $names) {
  $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
  if ($vm) {
    if ($vm.State -ne "Off") {
      Stop-VM -Name $name -Force | Out-Null
    }
    Remove-VM -Name $name -Force
    Write-Host "Removed VM: $name" -ForegroundColor Green
  }
}

if (Test-Path $VmRoot) {
  Remove-Item -Path $VmRoot -Recurse -Force
  Write-Host "Removed VM root: $VmRoot" -ForegroundColor Green
}

if ($RemoveSwitch -and $switchName) {
  $sw = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
  if ($sw) {
    Remove-VMSwitch -Name $switchName -Force
    Write-Host "Removed switch: $switchName" -ForegroundColor Green
  }
}

Write-Host "Hyper-V teardown complete."
