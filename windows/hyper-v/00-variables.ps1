# PQC PKI Lab on Hyper-V - Variables
# Update these values before running the deployment scripts.

$LabName = "pqclab"

# Hyper-V host paths
$BaseVhdPath = "D:\HyperV\BaseImages\wsvnext-29550-gold.vhdx"   # vNext 29550+ prepared image
$VmRootPath = "D:\HyperV\PQCLab"
$HostStagingPath = "D:\HyperV\PQCLab\staging"

# Hyper-V networking
$VMSwitchName = "PQC-Lab-Switch"
$LabSubnetCidr = "10.10.0.0/24"
$HostVnicIp = "10.10.0.1"
$HostPrefixLength = 24
$NatName = "PQC-Lab-NAT"

# Guest network
$DcIp = "10.10.0.10"
$RootCaIp = "10.10.0.20"
$IssuingCaIp = "10.10.0.30"
$WebIp = "10.10.0.40"
$GatewayIp = "10.10.0.1"

# Domain
$DomainName = "pqclab.local"
$DomainNetbios = "PQCLAB"
$DomainAdminUser = "Administrator"
$SafeModePasswordPlain = "P@ssw0rd-DSRM-2026!"

# Local administrator (inside each VM before domain join)
$LocalAdminUser = "Administrator"
$LocalAdminPasswordPlain = "P@ssw0rd-LocalAdmin-2026!"

# VM names
$VmRootCa = "pqc-rootca"
$VmDc = "pqc-dc01"
$VmIssuingCa = "pqc-issuingca"
$VmWeb = "pqc-web01"

# VM sizing
$VmGeneration = 2
$CpuCount = 2
$MemoryStartupBytes = 4GB
$MemoryMinimumBytes = 2GB
$MemoryMaximumBytes = 8GB
$DiffDiskSizeBytes = 128GB

# Optional host-only setup defaults
$EnableHostNat = $true

