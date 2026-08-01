# PQC PKI Lab — Azure Deployment Guide

## Scripts in this folder

| Script | Purpose |
|--------|---------|
| `00-variables.ps1` | **Edit this first** — subscription ID, credentials, location, image names |
| `00-prepare-image.ps1` | Prepare vNext ISO → custom Azure Compute Gallery image (also adapt for Win11 ISO) |
| `01-deploy-infrastructure.ps1` | Deploy VNet, NSG, storage, and up to 5 VMs (4 Server + Win11 client) |
| `02-config-dc.ps1` | Promote Domain Controller, create AD forest |
| `03-config-rootca.ps1` | Install Root CA with ML-DSA-87 |
| `03b-copy-certs-between-vms.ps1` | Relay PKI files between VMs via Blob storage |
| `04-config-issuingca.ps1` | Install Enterprise Issuing CA with ML-DSA-65 |
| `05-config-tls-template.ps1` | Create TLS template + enroll Web Server cert |
| `06-enable-mlkem-tls.ps1` | Enable x25519_mlkem768 ML-KEM TLS key exchange on servers |
| `07-verify.ps1` | Verify chain, TLS binding, and print test instructions |
| `08-config-win11-client.ps1` | **NEW** Configure Win11 Insider Preview client: ML-KEM + Edge browser PQC verification |
| `99-cleanup.ps1` | Delete all Azure resources when done |

## Prerequisites

- Windows Server vNext Insider Preview ISO (Build 29550+)
  - Download: https://aka.ms/DownloadWindowsServerPreviews
  - Requires Windows Insider Program registration
- **Windows 11 Insider Preview ISO (Build 26100.8514+)** — for the client VM
  - Download from Windows Insider Program (Dev or Beta channel)
- Local Hyper-V host (for image preparation in 00-prepare-image.ps1)
- Azure CLI installed: https://aka.ms/installazurecliwindows
- AzCopy installed: https://aka.ms/downloadazcopy
- Azure subscription with Contributor access
- PowerShell 5.1 or 7+

## Execution Order

```
1.  Edit 00-variables.ps1        (set subscription, credentials, image versions)
2.  Run 00-prepare-image.ps1     (Server vNext — 30-60 min for VHD upload)
2b. Run 00-prepare-image.ps1     (Win11 Insider — adapt script for Win11 ISO + client OS image def)
3.  Run 01-deploy-infrastructure.ps1
4.  Run 02-config-dc.ps1
5.  Run 03-config-rootca.ps1
6.  Run 03b-copy-certs-between-vms.ps1
7.  Run 04-config-issuingca.ps1
8.  Run 05-config-tls-template.ps1
9.  Run 06-enable-mlkem-tls.ps1
10. Run 07-verify.ps1
11. Run 08-config-win11-client.ps1   ← PQC TLS browser verification
```

> **Note:** Step 2b is independent of step 2 — both uploads can run in parallel on
> different Hyper-V VMs if you have the resources.

## Cost Estimate (East US, August 2026)

| Resource | Size | Est. $/month |
|----------|------|--------------|
| 4x Standard_B2ms Server VMs | 2 vCPU, 8 GB | ~$280 |
| 1x Standard_B2ms Win11 Client VM | 2 vCPU, 8 GB | ~$70 |
| 5x Premium SSD 128GB | P10 | ~$100 |
| Azure Bastion | Standard | ~$140 |
| Storage | LRS | ~$5 |
| **Total (running 24/7)** | | **~$595/mo** |

> **Tip:** Deallocate VMs when not in use. Cost drops to ~$35/mo for storage only.
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
    ├── rootca        10.10.1.20  Standalone Root CA        (ML-DSA-87, offline after setup)
    ├── dc01          10.10.1.10  Domain Controller          (pqclab.local, DNS)
    ├── issuingca     10.10.1.30  Enterprise Issuing CA      (ML-DSA-65, domain-joined)
    ├── webserver01   10.10.1.40  IIS Web Server             (ML-DSA-65 cert, ML-KEM TLS)
    └── win11client   10.10.1.50  Win11 Insider Test Client  (ML-KEM + Edge DevTools verification)
```

## Key Limitations

- **No Marketplace image** — both vNext and Win11 Insider Preview must be uploaded as custom VHDs
- **ML-DSA signature-only** — certificate template Purpose MUST be set to Signature
- **ML-KEM disabled by default** — must explicitly enable with Enable-TlsEccCurve on both server AND client
- **TLS 1.3 required for ML-KEM** — ML-KEM hybrid groups are TLS 1.3-only
- **Edge browser recommended** — Chrome/Firefox ML-DSA support unconfirmed as of August 2026
- **Win11 build minimum** — client must be Insider Preview build 26100.8514 or later for ML-KEM support
- **Not for production** — Insider Preview builds are pre-release, test lab only
