. "$PSScriptRoot\00-common.ps1"

Write-Step "Creating/validating Hyper-V virtual switch..."

if (-not (Get-VMSwitch -Name $VMSwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $VMSwitchName -SwitchType Internal | Out-Null
    Write-Host "Created internal switch: $VMSwitchName"
}

$hostAdapterName = "vEthernet ($VMSwitchName)"
$hostAdapter = Get-NetAdapter -Name $hostAdapterName -ErrorAction SilentlyContinue
if (-not $hostAdapter) {
    throw "Could not find host adapter '$hostAdapterName' after switch creation."
}

if (-not (Get-NetIPAddress -InterfaceAlias $hostAdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -eq $HostVnicIp})) {
    New-NetIPAddress -InterfaceAlias $hostAdapterName -IPAddress $HostVnicIp -PrefixLength $HostPrefixLength -ErrorAction SilentlyContinue | Out-Null
}

if ($EnableHostNat) {
    if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $LabSubnetCidr | Out-Null
    }
}

Write-Step "Creating VMs..."
Ensure-Folder -Path $VmRootPath

$vmMap = @(
    @{ Name = $VmDc;       Ip = $DcIp },
    @{ Name = $VmRootCa;   Ip = $RootCaIp },
    @{ Name = $VmIssuingCa;Ip = $IssuingCaIp },
    @{ Name = $VmWeb;      Ip = $WebIp }
)

foreach ($vm in $vmMap) {
    $vmName = $vm.Name
    $vmPath = Join-Path $VmRootPath $vmName
    $vhdPath = Join-Path $vmPath "$vmName.vhdx"

    Ensure-Folder -Path $vmPath

    if (-not (Test-Path $vhdPath)) {
        New-VHD -Path $vhdPath -ParentPath $BaseVhdPath -Differencing | Out-Null
    }

    if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        New-VM -Name $vmName -Generation $VmGeneration -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdPath -Path $vmPath -SwitchName $VMSwitchName | Out-Null
        Set-VMProcessor -VMName $vmName -Count $CpuCount
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes $MemoryMinimumBytes -MaximumBytes $MemoryMaximumBytes -StartupBytes $MemoryStartupBytes
        Enable-VMIntegrationService -VMName $vmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Created VM: $vmName"
    }

    if ((Get-VM -Name $vmName).State -ne "Running") {
        Start-VM -Name $vmName | Out-Null
    }
}

Write-Step "Waiting for VMs to be reachable via PowerShell Direct..."
foreach ($vm in @($VmDc, $VmRootCa, $VmIssuingCa, $VmWeb)) {
    Wait-VMReadyForDirect -VmName $vm
    Write-Host "Ready: $vm"
}

Write-Step "Applying static network config + hostnames..."

$netConfig = @(
    @{ Vm = $VmDc; Name = "dc01";       Ip = $DcIp;       Dns = @($DcIp) },
    @{ Vm = $VmRootCa; Name = "rootca"; Ip = $RootCaIp;   Dns = @($DcIp) },
    @{ Vm = $VmIssuingCa; Name = "issuingca"; Ip = $IssuingCaIp; Dns = @($DcIp) },
    @{ Vm = $VmWeb; Name = "webserver01"; Ip = $WebIp;    Dns = @($DcIp) }
)

foreach ($entry in $netConfig) {
    Invoke-InVmLocal -VmName $entry.Vm -ArgumentList $entry.Name, $entry.Ip, $GatewayIp, $entry.Dns -ScriptBlock {
        param($NewName, $Ip, $Gateway, $DnsServers)

        $nic = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
        if (-not $nic) { throw "No active NIC found." }

        $ifIndex = $nic.ifIndex
        Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $Ip -PrefixLength 24 -DefaultGateway $Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DnsServers

        if ($env:COMPUTERNAME -ne $NewName) {
            Rename-Computer -NewName $NewName -Force
        }
    }
    Restart-VmAndWait -VmName $entry.Vm
}

Write-Step "VM provisioning complete."

