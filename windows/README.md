# PQC PKI Test Lab

Automated deployment scripts for a **post-quantum cryptography (PQC) PKI test lab** using
Windows Server 2025 GA + KB5099536 (recommended) or Windows Server vNext Insider Preview
(Build 29550+). The lab deploys a two-tier certificate
authority that issues ML-DSA certificates, enables ML-KEM hybrid TLS key exchange, and
includes a **Windows 11 client VM** for end-to-end browser-level PQC verification
— confirming a fully PQC-safe TLS 1.3 session using NIST standards FIPS 203 and FIPS 204.

> **July 14, 2026 Update:** ML-KEM hybrid TLS is now available in GA builds — Windows Server 2025
> GA with KB5099536 and Win11 24H2 GA with KB5101650. Windows Insider Preview is no longer required
> for the ML-KEM TLS key exchange piece. ML-DSA certificate issuance still requires vNext 29550+ or
> Server 2025 + KB5087539 on the CA servers.

---

## What this lab builds

```
rootca          Standalone Root CA         ML-DSA-87 (FIPS 204, Level 5)    Offline after setup
dc01            Domain Controller          AD DS + DNS  pqclab.local
issuingca       Enterprise Issuing CA      ML-DSA-65 (FIPS 204, Level 3)    Domain-joined
webserver01     IIS Web Server             ML-DSA-65 TLS cert + x25519_mlkem768 key exchange
win11client     Windows 11 GA Client       ML-KEM enabled + Edge DevTools PQC verification
```

After deployment you get a running HTTPS endpoint validated from a real Win11 client where:

| TLS Component | Algorithm | Standard |
|---|---|---|
| Certificate signature | ML-DSA-65 (signed by ML-DSA-87 Root) | FIPS 204 |
| TLS key exchange | x25519_mlkem768 hybrid | FIPS 203 |
| Session cipher | AES-256-GCM | TLS 1.3 |

The Win11 client lets you confirm PQC negotiation via **Edge F12 → Security tab** — the
key exchange group (`x25519_mlkem768`) is visible there, confirming both endpoints negotiated
post-quantum key establishment, not just classical X25519.

---

## Deployment options

Two independent deployment paths are provided. Choose the one that matches your environment:

| | Azure | Hyper-V |
|---|---|---|
| **Location** | [`pqc-azure-deploy/`](./pqc-azure-deploy/) | [`pqc-hyperv-deploy/`](./pqc-hyperv-deploy/) |
| **Host requirements** | Azure subscription (Contributor) + local Azure CLI | Windows host with Hyper-V role enabled |
| **VM lifecycle** | `az vm deallocate` to pause; `az group delete` to clean up | Local VMs managed with Hyper-V Manager or PowerShell |
| **Networking** | Azure VNet 10.10.1.0/24 with NSG + optional Bastion | Internal Hyper-V switch 10.10.0.0/24 with host NAT |
| **Script engine** | Azure CLI (`az vm run-command`) — runs from your workstation | PowerShell Direct — runs from the Hyper-V host |
| **PKI file transfer** | Blob Storage with SAS tokens | Direct VM-to-host `Copy-Item` over PowerShell Direct |
| **Cost** | ~$595/month running 24/7; ~$35/month when deallocated | Free (uses local hardware) |
| **Internet required** | Yes — for Azure deployment and RDP access | No — lab is fully local once ISOs are downloaded |
| **Time to first HTTPS** | ~60–90 min (includes ~40 min VHD upload) | ~30–45 min (faster if base images already exist) |
| **Best for** | Sharing with a team, remote access, no local resources | Local dev/testing, no Azure subscription, offline use |

---

## Choosing a path

**Choose Azure if:**
- You want to share the lab with colleagues or access it remotely.
- You don't have a machine with enough RAM/CPU for 5 VMs.
- You want to tear down completely with a single command when done.
- You are already operating in an Azure-first workflow.

**Choose Hyper-V if:**
- You want to work offline or without an Azure subscription.
- You have a capable Windows workstation or server with Hyper-V available.
- You want faster iteration (no VHD upload step, no network latency to VMs).
- You want to keep costs at zero.

Both paths produce the same PKI topology and the same final TLS profile.

---

## Prerequisites (both paths)

- Windows Server 2025 GA ISO + KB5099536 (recommended)
  - Download from the Evaluation Center or Volume Licensing portal
  - Apply July 14, 2026 updates until build **26100.33158** or later
- Windows Server vNext Insider Preview ISO, build **29550 or later** (alternative)
  - Register and download: https://aka.ms/DownloadWindowsServerPreviews
  - Requires Windows Insider Program membership (free)
- **Windows 11 ISO — build 26100.8524+ with KB5101650 (GA Win11 24H2/25H2)** — for the client VM
  - As of **July 14, 2026**, Insider Preview is **no longer required** for the client ML-KEM piece
  - GA Win11 24H2/25H2 + **KB5101650** (production) or **KB5089573** (preview, build 26100.8524+)
  - Win11 26H1 GA + **KB5095091** also qualifies
  - Win11 Insider Preview build 26100.8514+ remains valid (original minimum)
  - The client VM is optional but strongly recommended for browser-level PQC verification
- PowerShell 5.1 or 7+

---

## Azure path — quick start

```
cd pqc-azure-deploy

# 1. Edit configuration
notepad 00-variables.ps1          # Set SUBSCRIPTION_ID, ADMIN_PASS, LOCATION

# 2. Prepare the custom server image (run on a local Hyper-V host, ~60 min)
.\00-prepare-image.ps1            # Server 2025 GA + KB5099536 or vNext 29550+ image
# Repeat for Win11 24H2 GA (adapt 00-prepare-image.ps1 for Win11 ISO + client OS image def)

# 3. Deploy infrastructure (VNet, NSG, up to 5 VMs)
.\01-deploy-infrastructure.ps1

# 4-10. Configure each layer in order
.\02-config-dc.ps1
.\03-config-rootca.ps1
.\03b-copy-certs-between-vms.ps1
.\04-config-issuingca.ps1
.\05-config-tls-template.ps1
.\06-enable-mlkem-tls.ps1
.\07-verify.ps1

# 11. Configure Win11 client + run PQC TLS verification
.\08-config-win11-client.ps1
```

**Additional Azure prerequisites:**
- Azure CLI: https://aka.ms/installazurecliwindows
- AzCopy: https://aka.ms/downloadazcopy

See [`pqc-azure-deploy/README.md`](./pqc-azure-deploy/README.md) for full details and cost breakdown.

---

## Hyper-V path — quick start

```
cd pqc-hyperv-deploy

# 1. Edit configuration (run as Administrator from Hyper-V host)
notepad 00-variables.ps1          # Set BaseVhdPath, Win11BaseVhdPath, VmRootPath, passwords

# 2. Verify host readiness
.\01-prereq-check.ps1

# 3. Create VMs, networking, and apply static IPs (creates Win11 client if Win11BaseVhdPath exists)
.\02-new-lab-vms.ps1

# 4-9. Configure each layer in order
.\03-config-dc.ps1
.\04-config-rootca.ps1
.\05-config-issuingca.ps1
.\06-config-webserver.ps1
.\07-enable-mlkem-tls.ps1
.\08-verify.ps1

# 10. Configure Win11 client + run PQC TLS verification
.\09-config-win11-client.ps1
```

**Hyper-V host requirements:**
- Hyper-V role enabled (Windows 10/11 Pro/Enterprise or Windows Server)
- 20+ GB RAM recommended (5 VMs at 4 GB each)
- ~300 GB free disk space (differencing disks keep it manageable)
- Run PowerShell as Administrator

See [`pqc-hyperv-deploy/README.md`](./pqc-hyperv-deploy/README.md) for full details.

---

## Repository structure

```
.
├── pqc-azure-deploy/               Azure CLI + az vm run-command deployment
│   ├── 00-variables.ps1            Edit first — subscription, names, IPs, image definitions
│   ├── 00-prepare-image.ps1        Convert vNext or Win11 ISO to Azure Compute Gallery image
│   ├── 01-deploy-infrastructure.ps1
│   ├── 02-config-dc.ps1
│   ├── 03-config-rootca.ps1
│   ├── 03b-copy-certs-between-vms.ps1
│   ├── 04-config-issuingca.ps1
│   ├── 05-config-tls-template.ps1
│   ├── 06-enable-mlkem-tls.ps1
│   ├── 07-verify.ps1
│   ├── 08-config-win11-client.ps1  Win11 24H2 GA client — ML-KEM + Edge PQC verification
│   ├── 99-cleanup.ps1
│   └── README.md
│
├── pqc-hyperv-deploy/              PowerShell Direct on Hyper-V host deployment
│   ├── 00-variables.ps1            Edit first — VM paths, IPs, passwords, image paths
│   ├── 00-common.ps1               Shared helper functions
│   ├── 01-prereq-check.ps1
│   ├── 02-new-lab-vms.ps1
│   ├── 03-config-dc.ps1
│   ├── 04-config-rootca.ps1
│   ├── 05-config-issuingca.ps1
│   ├── 06-config-webserver.ps1
│   ├── 07-enable-mlkem-tls.ps1
│   ├── 08-verify.ps1
│   ├── 09-config-win11-client.ps1  Win11 24H2 GA client — ML-KEM + Edge PQC verification
│   ├── 99-cleanup.ps1
│   └── README.md
│
└── README.md                       ← You are here
```

---

## PQC technical context

### What is ML-DSA?
ML-DSA (Module-Lattice Digital Signature Algorithm, FIPS 204) is a NIST-standardized
post-quantum signature algorithm. It replaces RSA and ECDSA in certificates. Windows Server
vNext build 29550+ and Windows Server 2025 + KB5087539 both support ML-DSA in AD CS.

### What is ML-KEM?
ML-KEM (Module-Lattice Key Encapsulation Mechanism, FIPS 203) is used for **TLS key exchange**
— not for certificate public keys. It protects session key establishment from quantum attack
(the "harvest now, decrypt later" threat). Hybrid groups `x25519_mlkem768`, `secp256r1_mlkem768`,
and `secp384r1_mlkem1024` must be explicitly enabled and are TLS 1.3-only.
**Both the server and the client must have ML-KEM enabled for negotiation to succeed.**

**July 14, 2026 update:** Microsoft's July 2026 Patch Tuesday backported ML-KEM hybrid TLS to
GA builds — it is no longer limited to Insider Preview:
- **Server 2025 GA:** KB5099536 (OS Build 26100.33158) enables ML-KEM TLS key exchange
- **Win11 24H2/25H2 GA:** KB5089573 (preview, build 26100.8524+) and KB5101650 (production)
- **Win11 26H1 GA:** KB5095091
- vNext 29550+ remains the single-image path that includes both ML-DSA (CA) and ML-KEM (TLS).

### Current limitations (as of August 2026)
| Limitation | Details |
|---|---|
| ML-DSA is signature-only | Cert template `Request Handling` Purpose must be set to `Signature`. Encryption EKUs are incompatible. |
| No composite certificates yet | Cannot combine a classical algorithm with ML-DSA in a single cert (Phase 2, no ship date). |
| ML-KEM keys not in certs | ML-KEM operates only in the TLS handshake; it is not embedded in the certificate itself. |
| ML-KEM disabled by default | Must explicitly call `Enable-TlsEccCurve` on **both** server and client. |
| TLS 1.3 required for ML-KEM | Hybrid groups are not available in TLS 1.2 or earlier. |
| Win11 client build (updated) | GA Win11 24H2 + KB5101650 (build 26100.8524+) now sufficient for ML-KEM. Insider Preview no longer required. Win11 26H1 + KB5095091 also works. Insider Preview 26100.8514+ still valid. |
| Server GA ML-KEM (updated) | Server 2025 GA + KB5099536 (July 14, 2026) now supports ML-KEM hybrid TLS. vNext 29550+ still required for ML-DSA cert issuance on CA servers. |
| Browser compatibility | Microsoft Edge (CNG-based) validates ML-DSA chains and shows KEM group in DevTools. Chrome/Firefox support unconfirmed as of August 2026. Use Edge for testing. |

---

## Security notes

- The default credentials in `00-variables.ps1` are **placeholders only**. Change them before running.
- The Root CA VM should be taken offline after signing the Issuing CA certificate.
- The NSG (Azure) and internal Hyper-V switch limit exposure — do not expose lab VMs publicly.
- This lab uses pre-release software and is **not suitable for production use**.

---

## References

- [Microsoft Learn — AD CS PQC Support](https://learn.microsoft.com/windows-server/identity/ad-cs)
- [Windows Server Insider Preview](https://aka.ms/DownloadWindowsServerPreviews)
- [NIST FIPS 203 — ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [NIST FIPS 204 — ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)

---

## What this lab builds

```
rootca          Standalone Root CA       ML-DSA-87 (FIPS 204, NIST Level 5)  Offline after setup
dc01            Domain Controller        AD DS + DNS  pqclab.local
issuingca       Enterprise Issuing CA    ML-DSA-65 (FIPS 204, NIST Level 3)  Domain-joined
webserver01     IIS Web Server           ML-DSA-65 TLS cert + x25519_mlkem768 key exchange
```

After deployment you get a running HTTPS endpoint where:

| TLS Component | Algorithm | Standard |
|---|---|---|
| Certificate signature | ML-DSA-65 (signed by ML-DSA-87 Root) | FIPS 204 |
| TLS key exchange | x25519_mlkem768 hybrid | FIPS 203 |
| Session cipher | AES-256-GCM | TLS 1.3 |

---

## Deployment options

Two independent deployment paths are provided. Choose the one that matches your environment:

| | Azure | Hyper-V |
|---|---|---|
| **Location** | [`pqc-azure-deploy/`](./pqc-azure-deploy/) | [`pqc-hyperv-deploy/`](./pqc-hyperv-deploy/) |
| **Host requirements** | Azure subscription (Contributor) + local Azure CLI | Windows host with Hyper-V role enabled |
| **VM lifecycle** | `az vm deallocate` to pause; `az group delete` to clean up | Local VMs managed with Hyper-V Manager or PowerShell |
| **Networking** | Azure VNet 10.10.1.0/24 with NSG + optional Bastion | Internal Hyper-V switch 10.10.0.0/24 with host NAT |
| **Script engine** | Azure CLI (`az vm run-command`) — runs from your workstation | PowerShell Direct — runs from the Hyper-V host |
| **PKI file transfer** | Blob Storage with SAS tokens | Direct VM-to-host `Copy-Item` over PowerShell Direct |
| **Cost** | ~$380/month running 24/7; ~$30/month when deallocated | Free (uses local hardware) |
| **Internet required** | Yes — for Azure deployment and RDP access | No — lab is fully local once ISO is downloaded |
| **Time to first HTTPS** | ~60–90 min (includes ~40 min VHD upload) | ~30–45 min (faster if base image already exists) |
| **Best for** | Sharing with a team, remote access, no local resources | Local dev/testing, no Azure subscription, offline use |

---

## Choosing a path

**Choose Azure if:**
- You want to share the lab with colleagues or access it remotely.
- You don't have a machine with enough RAM/CPU for 4 VMs.
- You want to tear down completely with a single command when done.
- You are already operating in an Azure-first workflow.

**Choose Hyper-V if:**
- You want to work offline or without an Azure subscription.
- You have a capable Windows workstation or server with Hyper-V available.
- You want faster iteration (no VHD upload step, no network latency to VMs).
- You want to keep costs at zero.

Both paths produce the same PKI topology and the same final TLS profile.

---

## Prerequisites (both paths)

- Windows Server vNext Insider Preview ISO, build **29550 or later**
  - Register and download: https://aka.ms/DownloadWindowsServerPreviews
  - Requires Windows Insider Program membership (free)
- PowerShell 5.1 or 7+

---

## Azure path — quick start

```
cd pqc-azure-deploy

# 1. Edit configuration
notepad 00-variables.ps1          # Set SUBSCRIPTION_ID, ADMIN_PASS, LOCATION

# 2. Prepare the custom server image (run on a local Hyper-V host, ~60 min)
.\00-prepare-image.ps1

# 3. Deploy infrastructure (VNet, NSG, 4 VMs)
.\01-deploy-infrastructure.ps1

# 4-10. Configure each layer in order
.\02-config-dc.ps1
.\03-config-rootca.ps1
.\03b-copy-certs-between-vms.ps1
.\04-config-issuingca.ps1
.\05-config-tls-template.ps1
.\06-enable-mlkem-tls.ps1
.\07-verify.ps1
```

**Additional Azure prerequisites:**
- Azure CLI: https://aka.ms/installazurecliwindows
- AzCopy: https://aka.ms/downloadazcopy

See [`pqc-azure-deploy/README.md`](./pqc-azure-deploy/README.md) for full details and cost breakdown.

---

## Hyper-V path — quick start

```
cd pqc-hyperv-deploy

# 1. Edit configuration (run as Administrator from Hyper-V host)
notepad 00-variables.ps1          # Set BaseVhdPath, VmRootPath, passwords

# 2. Verify host readiness
.\01-prereq-check.ps1

# 3. Create VMs, networking, and apply static IPs
.\02-new-lab-vms.ps1

# 4-9. Configure each layer in order
.\03-config-dc.ps1
.\04-config-rootca.ps1
.\05-config-issuingca.ps1
.\06-config-webserver.ps1
.\07-enable-mlkem-tls.ps1
.\08-verify.ps1
```

**Hyper-V host requirements:**
- Hyper-V role enabled (Windows 10/11 Pro/Enterprise or Windows Server)
- 16+ GB RAM recommended (4 VMs at 4 GB each)
- ~200 GB free disk space
- Run PowerShell as Administrator

See [`pqc-hyperv-deploy/README.md`](./pqc-hyperv-deploy/README.md) for full details.

---

## Repository structure

```
.
├── pqc-azure-deploy/               Azure CLI + az vm run-command deployment
│   ├── 00-variables.ps1            Edit first — subscription, names, IPs
│   ├── 00-prepare-image.ps1        Convert Server 2025 GA or vNext ISO to Azure Compute Gallery image
│   ├── 01-deploy-infrastructure.ps1
│   ├── 02-config-dc.ps1
│   ├── 03-config-rootca.ps1
│   ├── 03b-copy-certs-between-vms.ps1
│   ├── 04-config-issuingca.ps1
│   ├── 05-config-tls-template.ps1
│   ├── 06-enable-mlkem-tls.ps1
│   ├── 07-verify.ps1
│   ├── 99-cleanup.ps1
│   └── README.md
│
├── pqc-hyperv-deploy/              PowerShell Direct on Hyper-V host deployment
│   ├── 00-variables.ps1            Edit first — VM paths, IPs, passwords
│   ├── 00-common.ps1               Shared helper functions
│   ├── 01-prereq-check.ps1
│   ├── 02-new-lab-vms.ps1
│   ├── 03-config-dc.ps1
│   ├── 04-config-rootca.ps1
│   ├── 05-config-issuingca.ps1
│   ├── 06-config-webserver.ps1
│   ├── 07-enable-mlkem-tls.ps1
│   ├── 08-verify.ps1
│   ├── 99-cleanup.ps1
│   └── README.md
│
└── README.md                       ← You are here
```

---

## PQC technical context

### What is ML-DSA?
ML-DSA (Module-Lattice Digital Signature Algorithm, FIPS 204) is a NIST-standardized
post-quantum signature algorithm. It replaces RSA and ECDSA in certificates. Windows Server
vNext build 29550+ and Windows Server 2025 + KB5087539 both support ML-DSA in AD CS.

### What is ML-KEM?
ML-KEM (Module-Lattice Key Encapsulation Mechanism, FIPS 203) is used for **TLS key exchange**
— not for certificate public keys. It protects session key establishment from quantum attack
(the "harvest now, decrypt later" threat). Windows vNext 29550+ supports hybrid groups
`x25519_mlkem768`, `secp256r1_mlkem768`, and `secp384r1_mlkem1024` — these must be explicitly
enabled and are TLS 1.3-only.

### Current limitations (as of August 2026)
| Limitation | Details |
|---|---|
| ML-DSA is signature-only | Cert template `Request Handling` Purpose must be set to `Signature`. Encryption EKUs are incompatible. |
| No composite certificates yet | Cannot combine a classical algorithm with ML-DSA in a single cert (Phase 2, no ship date). |
| ML-KEM keys not in certs | ML-KEM operates only in the TLS handshake; it is not embedded in the certificate itself. |
| ML-KEM disabled by default | Must explicitly call `Enable-TlsEccCurve` on both server and client. |
| TLS 1.3 required for ML-KEM | Hybrid groups are not available in TLS 1.2 or earlier. |
| Browser compatibility | Microsoft Edge (CNG-based) validates ML-DSA chains. Chrome/Firefox support unconfirmed as of August 2026. Use Edge for testing. |

---

## Security notes

- The default credentials in `00-variables.ps1` are **placeholders only**. Change them before running.
- The Root CA VM should be taken offline after signing the Issuing CA certificate.
- The NSG (Azure) and internal Hyper-V switch limit exposure — do not expose lab VMs publicly.
- This lab uses pre-release software and is **not suitable for production use**.

---

## References

- [Microsoft Learn — AD CS PQC Support](https://learn.microsoft.com/windows-server/identity/ad-cs)
- [Windows Server Insider Preview](https://aka.ms/DownloadWindowsServerPreviews)
- [NIST FIPS 203 — ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [NIST FIPS 204 — ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)
- [Windows Insider Program for Business](https://insider.windows.com/business)
