# PQC PKI Lab on Hyper-V - Variables
# Update these values before running the deployment scripts.

$LabName = "pqclab"

# ----- Deployment Mode -------------------------------------------------------
# "GA"    — Windows Server 2025 GA + KB5087539 (ML-DSA) + KB5099536 (ML-KEM TLS) [RECOMMENDED]
#           Requires only production Windows Update — no Insider subscription needed.
# "vNext" — Windows Server vNext Insider Preview 29550+  (all PQC features built-in)
$DeploymentMode = "GA"

# Hyper-V host paths
$VNextBaseVhdPath = "D:\HyperV\BaseImages\wsvnext-29550-gold.vhdx"          # vNext 29550+
$GaBaseVhdPath    = "D:\HyperV\BaseImages\ws2025-26100.33158-gold.vhdx"     # Server 2025 GA + KB5099536
$BaseVhdPath = if ($DeploymentMode -eq "GA") { $GaBaseVhdPath } else { $VNextBaseVhdPath }
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
$SvcCaPasswordPlain    = "P@ssw0rd-SvcCA-2026!"  # svc-ca-enroll AD service account

# Local administrator (inside each VM before domain join)
$LocalAdminUser = "Administrator"
$LocalAdminPasswordPlain = "P@ssw0rd-LocalAdmin-2026!"

# VM names
$VmRootCa = "pqc-rootca"
$VmDc = "pqc-dc01"
$VmIssuingCa = "pqc-issuingca"
$VmWeb = "pqc-web01"
$VmClient = "pqc-win11client"   # Windows 11 PQC test client (GA 24H2 + KB5101650 or Insider Preview)

# VM sizing
$VmGeneration = 2
$CpuCount = 2
$MemoryStartupBytes = 4GB
$MemoryMinimumBytes = 2GB
$MemoryMaximumBytes = 8GB
$DiffDiskSizeBytes = 128GB

# Optional host-only setup defaults
$EnableHostNat = $true

# Windows 11 client image
# As of July 14, 2026, GA Win11 24H2/25H2 + KB5101650 (build 26100.8524+) is sufficient.
# Win11 26H1 + KB5095091 also works. Insider Preview 26100.8514+ remains valid.
# Separate base VHDX required — sysprepped with local Administrator account set.
$Win11BaseVhdPath = "D:\HyperV\BaseImages\win11-26100-ga-gold.vhdx"
$ClientIp = "10.10.0.50"

