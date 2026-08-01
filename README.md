# PQC Lab — Deployment Guide

Automated deployment scripts for a **post-quantum cryptography (PQC) PKI test lab**. Two
independent paths are provided — one Windows-native and one Linux-native — both producing a
fully PQC-safe TLS 1.3 endpoint using NIST standards **FIPS 203 (ML-KEM)** and **FIPS 204 (ML-DSA)**.

> **⚠️ Not for production.** Both paths use pre-release or experimental software components.
> This lab is for testing and evaluation only.

---

## Choose a Path

| | [Windows Path](#windows-path) | [Ubuntu Path](#ubuntu-path) |
|---|---|---|
| **OS** | Windows Server vNext Insider Preview (Build 29550+) | Ubuntu 26.04 LTS |
| **PKI stack** | Active Directory Certificate Services (AD CS) | OpenSSL 3.x + LibOQS or SymCrypt provider |
| **CA hierarchy** | Root CA → Enterprise Issuing CA → Server Cert (AD DS-integrated) | Root CA → Intermediate CA → Server Cert (standalone) |
| **Web server** | IIS | Apache 2.4 + mod_ssl |
| **ML-DSA** | ML-DSA-87 (Root) / ML-DSA-65 (Issuing + Leaf) | ML-DSA-87 (Root) / ML-DSA-65 (Intermediate + Leaf) |
| **ML-KEM** | x25519\_mlkem768 (via `Enable-TlsEccCurve`) | x25519\_mlkem768 (via Apache `SSLOpenSSLConfCmd Groups`) |
| **Scripting** | PowerShell | Bash (orchestrator) + PowerShell (Hyper-V infra only) |
| **Deployment targets** | Azure or Hyper-V | Azure or Hyper-V |
| **VM count** | 5 (Root CA, DC, Issuing CA, Web Server, Win11 Client) | 3 (CA Server, Web Server, Client) |
| **Best for** | Windows-first environments, AD CS familiarity, Domain-joined PKI | Linux environments, OpenSSL workflows, provider comparison (LibOQS vs SymCrypt) |

Both paths produce an HTTPS endpoint with the same TLS profile:

| TLS Component | Algorithm | Standard |
|---|---|---|
| Certificate signature | ML-DSA-65 (chained to ML-DSA-87 Root) | FIPS 204 |
| TLS key exchange | x25519\_mlkem768 hybrid | FIPS 203 |
| Session cipher | AES-256-GCM | TLS 1.3 |

---

## Windows Path

**Repository:** [`pqc-lab-windows/`](./pqc-lab-windows/)

Deploys a two-tier PKI on Windows Server vNext Insider Preview using AD CS. The lab includes
an Active Directory domain (`pqclab.local`), a standalone Root CA, an Enterprise Issuing CA,
an IIS web server, and a **Windows 11 Insider Preview client VM** for end-to-end browser-level
PQC verification — confirming PQC key exchange via Edge DevTools, not just server-side tooling.

### What gets deployed

```
rootca          Standalone Root CA         ML-DSA-87 (FIPS 204, Level 5)   Offline after setup
dc01            Domain Controller          AD DS + DNS  pqclab.local
issuingca       Enterprise Issuing CA      ML-DSA-65 (FIPS 204, Level 3)   Domain-joined
webserver01     IIS Web Server             ML-DSA-65 TLS cert + x25519_mlkem768 key exchange
win11client     Windows 11 Insider Client  ML-KEM enabled + Edge DevTools PQC verification
```

After deployment, confirm PQC negotiation via **Edge F12 → Security tab** on the Win11 client
— the key exchange group (`x25519_mlkem768`) is visible there, proving both endpoints negotiated
post-quantum key establishment, not just classical X25519.

### Prerequisites (Windows path)

- Windows Server vNext Insider Preview ISO, build **29550 or later**
  - Register and download: https://aka.ms/DownloadWindowsServerPreviews
  - Requires Windows Insider Program membership (free)
- **Windows 11 Insider Preview ISO, build 26100.8514 or later** — for the client VM
  - Download from the Windows Insider Program (Dev or Beta channel)
  - Optional but strongly recommended for browser-level PQC verification
- PowerShell 5.1 or 7+

### Windows → Azure

| Attribute | Value |
|---|---|
| **Host requirements** | Azure subscription (Contributor) + Azure CLI + AzCopy |
| **Networking** | Azure VNet 10.10.1.0/24 with NSG + optional Bastion |
| **Script engine** | `az vm run-command` — runs from your workstation |
| **PKI file transfer** | Blob Storage with SAS tokens |
| **Cost** | ~$595/month running 24/7; ~$35/month when deallocated |
| **Time to first HTTPS** | ~60–90 min (includes ~40 min VHD upload) |
| **Best for** | Sharing with a team, remote access, no local hardware |

**Quick start:**

```powershell
cd pqc-azure-deploy

# 1. Edit configuration
notepad 00-variables.ps1          # Set SUBSCRIPTION_ID, ADMIN_PASS, LOCATION

# 2. Prepare images (run on a local Hyper-V host, ~60 min each)
.\00-prepare-image.ps1            # Server vNext 29550+ image
# Repeat for Win11 Insider Preview (adapt for Win11 ISO + client OS image definition)

# 3. Deploy infrastructure (VNet, NSG, up to 5 VMs)
.\01-deploy-infrastructure.ps1

# 4–10. Configure each layer in order
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

**Additional prerequisites:** Azure CLI (`https://aka.ms/installazurecliwindows`) and AzCopy (`https://aka.ms/downloadazcopy`).

### Windows → Hyper-V

| Attribute | Value |
|---|---|
| **Host requirements** | Windows 10/11 Pro/Enterprise or Windows Server with Hyper-V role enabled |
| **RAM** | 20+ GB recommended (5 VMs × 4 GB each) |
| **Disk** | ~300 GB free (differencing disks keep it manageable) |
| **Networking** | Internal Hyper-V switch 10.10.0.0/24 with host NAT |
| **Script engine** | PowerShell Direct — runs from the Hyper-V host |
| **Cost** | Free (uses local hardware) |
| **Time to first HTTPS** | ~30–45 min (faster if base image already exists) |
| **Best for** | Local dev/testing, no Azure subscription, offline use |

**Quick start:**

```powershell
cd pqc-hyperv-deploy

# 1. Edit configuration (run as Administrator from Hyper-V host)
notepad 00-variables.ps1          # Set BaseVhdPath, Win11BaseVhdPath, VmRootPath, passwords

# 2. Verify host readiness
.\01-prereq-check.ps1

# 3. Create VMs, networking, and apply static IPs (creates Win11 client if Win11BaseVhdPath exists)
.\02-new-lab-vms.ps1

# 4–9. Configure each layer in order
.\03-config-dc.ps1
.\04-config-rootca.ps1
.\05-config-issuingca.ps1
.\06-config-webserver.ps1
.\07-enable-mlkem-tls.ps1
.\08-verify.ps1

# 10. Configure Win11 client + run PQC TLS verification
.\09-config-win11-client.ps1
```

### Windows path — choosing Azure vs Hyper-V

**Choose Azure if:**
- You want to share the lab with colleagues or access it remotely.
- You don't have a machine with enough RAM/CPU for 5 VMs.
- You want to tear down completely with a single command.
- You are already in an Azure-first workflow.

**Choose Hyper-V if:**
- You want to work offline or without an Azure subscription.
- You have a capable Windows workstation or server with Hyper-V available.
- You want faster iteration (no VHD upload step, no network latency to VMs).
- You want to keep costs at zero.

---

## Ubuntu Path

**Repository:** [`pqc-lab-ubuntu/`](./pqc-lab-ubuntu/)

Deploys a post-quantum PKI stack on Ubuntu 26.04 LTS using OpenSSL 3.x. A key differentiator
is the choice of **PQ provider**: LibOQS (academic, broad algorithm support, fast to build) or
SymCrypt (Microsoft, FIPS 140-3 validated on Windows, Linux validation in progress). Both
providers are OpenSSL 3.x modules — once installed, all `openssl` commands and Apache directives
are identical. Switch providers by changing one environment variable.

### What gets deployed

```
pq-ca-vm        CA Server     Root CA (ML-DSA-87, 20yr) + Intermediate CA (ML-DSA-65, 10yr)
                              + Server Cert (ML-DSA-65, 825d)  |  OpenSSL 3.x + PQ provider
pq-web-vm       Web Server    Apache 2.4 + mod_ssl | TLS 1.3 + x25519_mlkem768 | ML-DSA-65 cert
pq-client-vm    TLS Client    Independent verification: TLS 1.3, ML-DSA chain, PQ key exchange,
                              TLS 1.2 rejection
```

### Provider comparison

| Attribute | LibOQS | SymCrypt |
|---|---|---|
| **Origin** | Open Quantum Safe academic consortium | Microsoft (core of Windows, Azure, M365) |
| **Algorithm scope** | Very broad — ML-DSA, ML-KEM, SLH-DSA, BIKE, HQC, Falcon, SPHINCS+ | Focused — ML-KEM + ML-DSA (FIPS-selected) + classical |
| **FIPS status** | Not FIPS validated | FIPS 140-3 validated (Windows); Linux validation in progress |
| **Build time** | ~5 minutes | ~15–20 minutes |
| **Min VM RAM** | 4 GB | 16 GB (compiler peaks ~8 GB) |
| **Best for** | Learning, interop testing, prototyping | Microsoft-aligned environments, FIPS requirements |

> 💡 Validate your PKI design with LibOQS, then switch to SymCrypt for production — no certificate
> issuance or Apache config commands change.

### Prerequisites (Ubuntu path)

- Azure CLI ≥ 2.60 (Azure path) — `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`
- `jq` — `sudo apt install jq`
- SSH key pair (scripts use `~/.ssh/id_rsa`)
- For Hyper-V: a prepared Ubuntu 26.04 VHDX with SSH server running and your public key in `~/.ssh/authorized_keys`
- WSL or Git Bash for running `00-remote-deploy.sh`

### Ubuntu → Azure

| Attribute | Value |
|---|---|
| **Host requirements** | Azure subscription + Azure CLI |
| **VM image** | Canonical Ubuntu 26.04 LTS (Marketplace) |
| **Networking** | Azure VNet, NSG, public IPs |
| **Cost** | ~$461/month (3 × Standard\_D4s\_v5 running 24/7) |
| **Teardown** | `./99-teardown.sh` (deletes entire resource group) |
| **Best for** | Quick spin-up, no local hardware, team sharing |

**Quick start:**

```bash
cd pq-ca-azure/

export PROVIDER=liboqs          # or: symcrypt
export ADMIN_IP="$(curl -s https://ifconfig.me)/32"

# Optional overrides
export PREFIX=pq-ca
export REGION=eastus
export VM_SIZE=Standard_D4s_v5  # minimum — do not reduce for SymCrypt

./01-azure-infra.sh             # provision 3 VMs + VNet + NSGs
./00-remote-deploy.sh           # build CA, deploy, verify
```

> 💡 Deallocate VMs when not testing: `az vm deallocate -g $RG -n pq-ca-ca-vm`

### Ubuntu → Hyper-V

| Attribute | Value |
|---|---|
| **Host requirements** | Windows host with Hyper-V enabled; ≥32 GB RAM recommended |
| **VM image** | Your prepared Ubuntu 26.04 VHDX (differencing disks — base never modified) |
| **Networking** | Hyper-V internal/external switch |
| **Cost** | Hardware you already own |
| **Teardown** | `.\99-teardown.ps1` (removes VMs + disks) |
| **Best for** | Air-gapped labs, on-prem testing, no Azure subscription |

**Quick start:**

```powershell
# Step 1 — provision VMs (PowerShell Admin)
cd pq-ca-hyperv\

.\01-hyperv-infra.ps1 `
  -BaseVhdx "C:\HyperV\BaseImages\ubuntu-26.04-template.vhdx" `
  -SwitchName "Default Switch" `
  -Provider "liboqs" `
  -AdminUser "azureuser"
```

```bash
# Step 2 — deploy everything (WSL or Git Bash)
cd pq-ca-hyperv/
chmod +x 00-remote-deploy.sh
./00-remote-deploy.sh
```

### Ubuntu path — choosing Azure vs Hyper-V

**Choose Azure if:**
- You want the fastest path from zero to a running environment.
- You do not have a Hyper-V host or adequate local RAM.
- You are evaluating PQ PKI for Azure-hosted production workloads.
- You need team access via public IPs.

**Choose Hyper-V if:**
- You need an air-gapped or isolated lab environment.
- You do not have an Azure subscription.
- You want to avoid ongoing cloud costs.
- You are testing for an on-premises or private cloud deployment scenario.

---

## PQC Technical Context

### ML-DSA vs ML-KEM — the most common point of confusion

| Algorithm | FIPS | Role | Where it appears |
|---|---|---|---|
| **ML-DSA** (Dilithium) | FIPS 204 | Digital signature | Certificate key algorithm |
| **ML-KEM** (Kyber) | FIPS 203 | Key encapsulation | TLS handshake only — **never** a certificate key |

ML-KEM protects session key establishment from quantum attack (the "harvest now, decrypt later"
threat). It does not appear in any certificate. TLS 1.3 is mandatory for ML-KEM to function.
**Both the server and the client must have ML-KEM enabled** for negotiation to succeed — this
is why the Windows path includes a Win11 client VM.

### Current limitations (as of August 2026)

| Limitation | Details |
|---|---|
| ML-DSA is signature-only | Windows: cert template `Request Handling` Purpose must be set to `Signature`. Encryption EKUs are incompatible. |
| No composite certificates yet | Cannot combine a classical algorithm with ML-DSA in a single cert (Phase 2, no ship date). |
| ML-KEM keys not in certs | ML-KEM operates only in the TLS handshake — it is not embedded in the certificate. |
| ML-KEM disabled by default (Windows) | Must explicitly call `Enable-TlsEccCurve` on **both** server and client. |
| TLS 1.3 required for ML-KEM | Hybrid groups are not available in TLS 1.2 or earlier. |
| Win11 client build minimum | Client VM must be Insider Preview build **26100.8514 or later** for ML-KEM support. |
| Browser compatibility (Windows path) | Microsoft Edge (CNG-based) validates ML-DSA chains and shows KEM group in DevTools. Chrome/Firefox support unconfirmed as of August 2026. Use Edge for testing. |
| LibOQS not FIPS validated | Labeled "not production ready" by the OQS project. Use SymCrypt for FIPS requirements. |

---

## Security Notes

- Default credentials in variable files are **placeholders only**. Change them before running.
- The Root CA VM should be taken offline after signing the Issuing/Intermediate CA certificate.
- NSGs (Azure) and internal Hyper-V switches limit exposure — do not expose lab VMs to the public internet.
- Both paths use pre-release or experimental components and are **not suitable for production use**.

---

## References

- [NIST FIPS 203 — ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [NIST FIPS 204 — ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)
- [Microsoft Learn — AD CS PQC Support](https://learn.microsoft.com/windows-server/identity/ad-cs)
- [Windows Server Insider Preview](https://aka.ms/DownloadWindowsServerPreviews)
- [Windows Insider Program for Business](https://insider.windows.com/business)
- [Open Quantum Safe — liboqs](https://github.com/open-quantum-safe/liboqs)
- [Open Quantum Safe — oqs-provider](https://github.com/open-quantum-safe/oqs-provider)
- [Microsoft SymCrypt](https://github.com/microsoft/SymCrypt)
- [Microsoft SymCrypt-OpenSSL](https://github.com/microsoft/SymCrypt-OpenSSL)
