# PQC PKI Lab — Azure Deployment Guide

## Scripts in this folder

| Script | Purpose |
|--------|---------|
| `00-variables.ps1` | **Edit this first** — subscription ID, credentials, location |
| `00-prepare-image.ps1` | Prepare vNext ISO → custom Azure Compute Gallery image |
| `01-deploy-infrastructure.ps1` | Deploy VNet, NSG, storage, and 4 VMs |
| `02-config-dc.ps1` | Promote Domain Controller, create AD forest |
| `03-config-rootca.ps1` | Install Root CA with ML-DSA-87 |
| `03b-copy-certs-between-vms.ps1` | Relay PKI files between VMs via Blob storage |
| `04-config-issuingca.ps1` | Install Enterprise Issuing CA with ML-DSA-65 |
| `05-config-tls-template.ps1` | Create TLS template + enroll Web Server cert |
| `06-enable-mlkem-tls.ps1` | Enable x25519_mlkem768 ML-KEM TLS key exchange |
| `07-verify.ps1` | Verify chain, TLS binding, and print test instructions |
| `99-cleanup.ps1` | Delete all Azure resources when done |

## Prerequisites

- Windows Server vNext Insider Preview ISO (Build 29550+)
  - Download: https://aka.ms/DownloadWindowsServerPreviews
  - Requires Windows Insider Program registration
- Local Hyper-V host (for image preparation in 00-prepare-image.ps1)
- Azure CLI installed: https://aka.ms/installazurecliwindows
- AzCopy installed: https://aka.ms/downloadazcopy
- Azure subscription with Contributor access
- PowerShell 5.1 or 7+

## Execution Order

```
1. Edit 00-variables.ps1
2. Run 00-prepare-image.ps1    (on local Hyper-V host — takes 30-60 min for VHD upload)
3. Run 01-deploy-infrastructure.ps1
4. Run 02-config-dc.ps1
5. Run 03-config-rootca.ps1
6. Run 03b-copy-certs-between-vms.ps1
7. Run 04-config-issuingca.ps1
8. Run 05-config-tls-template.ps1
9. Run 06-enable-mlkem-tls.ps1
10. Run 07-verify.ps1
```

## Cost Estimate (East US, July 2026)

| Resource | Size | Est. $/month |
|----------|------|--------------|
| 4x Standard_B2ms VMs | 2 vCPU, 8 GB | ~$280 |
| 4x Premium SSD 128GB | P10 | ~$80 |
| Azure Bastion | Standard | ~$140 |
| Storage | LRS | ~$5 |
| **Total (running 24/7)** | | **~$505/mo** |

> **Tip:** Deallocate VMs when not in use. Cost drops to ~$30/mo for storage only.
> Run `az vm deallocate -g rg-pqc-lab --name <vm>` for each VM.

## Architecture

```
Internet
    │
    ▼
NSG (RDP locked to admin IP)
    │
Azure VNet 10.10.0.0/16
    │
    ├── rootca      10.10.1.20  Standalone Root CA   (ML-DSA-87, offline after setup)
    ├── dc01        10.10.1.10  Domain Controller     (pqclab.local, DNS)
    ├── issuingca   10.10.1.30  Enterprise Issuing CA (ML-DSA-65, domain-joined)
    └── webserver01 10.10.1.40  IIS Web Server        (ML-DSA-65 cert, ML-KEM TLS)
```

## Key Limitations

- **No Marketplace image** — vNext Insider Preview must be uploaded as a custom VHD
- **ML-DSA signature-only** — certificate template Purpose MUST be set to Signature
- **ML-KEM disabled by default** — must explicitly enable with Enable-TlsEccCurve
- **TLS 1.3 required for ML-KEM** — ML-KEM hybrid groups are TLS 1.3-only
- **Edge browser recommended** — Chrome/Firefox ML-DSA support unconfirmed as of July 2026
- **Not for production** — Insider Preview builds are pre-release, test lab only
