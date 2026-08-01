# Post-Quantum Certificate Authority — Ubuntu 26.04 LTS

Automated deployment of a post-quantum PKI stack on Ubuntu 26.04 LTS using either **LibOQS** or **Microsoft SymCrypt** as the OpenSSL 3.x provider. Deploys a full CA hierarchy (Root CA → Intermediate CA → Server Certificate) secured with **ML-DSA** keys, and an Apache 2.4 web server with **TLS 1.3 + ML-KEM** key exchange — proven end-to-end from a dedicated Ubuntu desktop client VM.

Two deployment paths are provided. Both produce identical results; the only difference is where the VMs run.

| | [Azure (cloud)](#azure-deployment) | [Hyper-V (on-premises)](#hyper-v-deployment) |
|---|---|---|
| **Best for** | Quick spin-up, no local hardware required | Air-gapped labs, on-prem testing, no Azure subscription |
| **Provisioning** | `az` CLI — Azure Resource Manager | PowerShell Hyper-V cmdlets |
| **VM image** | Canonical Ubuntu 26.04 LTS (Marketplace) | Your prepared Ubuntu 26.04 VHDX |
| **Networking** | Azure VNet, NSG, public IPs | Hyper-V internal/external switch |
| **Estimated cost** | ~$451/mo (3 × Standard_D4s_v5) | Hardware you already own |
| **Teardown** | `./99-teardown.sh` (deletes resource group) | `.\99-teardown.ps1` (removes VMs + disks) |
| **Orchestrator** | `00-remote-deploy.sh` (Bash) | `00-remote-deploy.sh` (Bash via WSL/Git Bash) |

---

## What gets deployed

```
┌─────────────────────────────────────────────────────┐
│  pq-ca-vm  (CA Server)                              │
│  ┌──────────────────────────────────────────────┐   │
│  │  OpenSSL 3.x + PQ Provider                  │   │
│  │  Root CA        ML-DSA-87  (20 yr)           │   │
│  │  Intermediate CA ML-DSA-65 (10 yr)           │   │
│  │  Server Cert    ML-DSA-65  (825 d)           │   │
│  └──────────────┬───────────────────────────────┘   │
│                 │ SCP certs + provider               │
│  pq-web-vm  (Apache TLS Endpoint)                   │
│  ┌──────────────▼───────────────────────────────┐   │
│  │  Apache 2.4 + mod_ssl                        │   │
│  │  SSLProtocol -all +TLSv1.3                   │   │
│  │  SSLOpenSSLConfCmd Groups x25519_mlkem768     │   │
│  └──────────────────────────────────────────────┘   │
│                 ▲ openssl s_client                   │
│  pq-client-vm  (Ubuntu Desktop TLS Client)           │
│  ┌──────────────────────────────────────────────┐   │
│  │  XFCE + Firefox GUI                           │   │
│  │  06-client-verify.sh                          │   │
│  │  Confirms TLS 1.3, ML-DSA cert,               │   │
│  │  PQ key exchange, TLS 1.2 rejection           │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## PQ Algorithm Reference

> ⚠️ These two algorithms are frequently confused. Read this before deploying.

| Algorithm | FIPS | Role | Where it appears |
|---|---|---|---|
| **ML-DSA** (Dilithium) | FIPS 204 | Digital signature | Certificate key algorithm (`ml-dsa-65`, `ml-dsa-87`) |
| **ML-KEM** (Kyber) | FIPS 203 | Key encapsulation | Apache `SSLOpenSSLConfCmd Groups` only — **never** a cert key |

ML-KEM is configured in Apache to control TLS key exchange during the handshake. It does not appear in any certificate. TLS 1.3 is mandatory for ML-KEM to function.

---

## Provider Comparison

Both providers are installed as OpenSSL 3.x modules (`.so`). Once installed, every `openssl` command and Apache directive is **identical** between them. Switch providers by changing one environment variable: `PROVIDER=liboqs` or `PROVIDER=symcrypt`.

| Attribute | LibOQS | SymCrypt |
|---|---|---|
| **Origin** | Open Quantum Safe academic consortium | Microsoft (core of Windows, Azure, M365) |
| **Algorithm scope** | Very broad — ML-DSA, ML-KEM, SLH-DSA, BIKE, HQC, Falcon, McEliece, SPHINCS+ | Focused — ML-KEM + ML-DSA (FIPS-selected) + classical |
| **FIPS status** | Not FIPS validated — labeled "not production ready" by OQS | FIPS 140-3 validated (Windows); Linux validation in progress |
| **Build time** | ~5 minutes | ~15–20 minutes |
| **Min VM RAM** | 4 GB (Standard_B2s for Azure) | 16 GB (Standard_D4s_v5) — compiler peaks ~8 GB |
| **Best for** | Learning, interop testing, prototyping | Microsoft-aligned environments, FIPS requirements, Azure production |

> 💡 **Key insight**: The OpenSSL provider abstraction means you can validate your PKI design with LibOQS and then switch to SymCrypt for production without changing any certificate issuance or Apache config commands.

---

## Azure Deployment

### Prerequisites

- Azure CLI ≥ 2.60 — `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`
- Logged in — `az login`
- `jq` — `sudo apt install jq`
- SSH key pair (scripts use `~/.ssh/id_rsa`)

### Quickstart

```bash
cd pq-ca-azure/

# Required
export PROVIDER=liboqs          # or: symcrypt
export ADMIN_IP="$(curl -s https://ifconfig.me)/32"

# Optional
export PREFIX=pq-ca
export REGION=eastus
export VM_SIZE=Standard_D4s_v5  # minimum — do not reduce for SymCrypt

./01-azure-infra.sh             # provision 3 VMs + VNet + NSGs
./00-remote-deploy.sh           # build CA, deploy, verify
```

### Expected output

```
══ Step 6: Verify from CA VM ══
  PASS  Port 443 is reachable
  PASS  TLS handshake succeeded and cert chain verified
  PASS  Server cert uses ML-DSA: id-ml-dsa-65
  PASS  TLS 1.3 negotiated
  PASS  PQ key exchange: X25519_MLKEM768
  PASS  Full chain validates to Root CA
  PASS  HTTP redirects to HTTPS (301)
  PASS  HSTS header present
RESULTS: 8/8 passed, 0 failed

══ Step 9: Verify from client VM ══
  PASS  TLS 1.3 handshake succeeded
  PASS  Certificate chain validates to trusted Root CA
  PASS  PQ/hybrid key exchange negotiated
  PASS  TLS 1.2 rejected as expected
RESULTS: 4/4 passed, 0 failed
```

### Azure cost estimate

| Resource | SKU | ~Monthly |
|---|---|---|
| 3 × VM Standard_D4s_v5 | 4 vCPU / 16 GB | ~$420 |
| 3 × Public IP Standard | Static | ~$11 |
| 3 × OS Disk Premium P10 | 128 GB | ~$30 |
| **Total** | | **~$461** |

> 💡 Deallocate VMs when not testing: `az vm deallocate -g $RG -n pq-ca-ca-vm`

### Teardown

```bash
./99-teardown.sh    # deletes entire resource group
```

---

## Hyper-V Deployment

### Prerequisites

- Windows host with Hyper-V feature enabled
- A prepared Ubuntu 26.04 VHDX with:
  - SSH server running
  - A login user (default: `azureuser`)
  - Your SSH public key in `~/.ssh/authorized_keys`
- A Hyper-V virtual switch (the built-in `Default Switch` works for most setups)
- WSL or Git Bash for running `00-remote-deploy.sh`

### Prepare the base VHDX

If you do not have a template VHDX, create one using the Hyper-V Quick Create gallery, install Ubuntu 26.04, enable SSH, inject your key, then shut down cleanly and use that VHDX as your `-BaseVhdx` argument. The scripts use differencing disks so your base image is never modified.

```powershell
# Verify your SSH key reaches the template before running infra
ssh azureuser@<template-vm-ip> "echo ok"
```

### Quickstart

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

### Teardown

```powershell
.\99-teardown.ps1
# Add -RemoveSwitch to also delete the virtual switch
```

---

## Script Inventory

Both deployment paths share the same set of Linux scripts for the CA and verification workflow. The only difference is the infrastructure provisioning layer.

### Shared Linux scripts (identical between Azure and Hyper-V)

| Script | Runs on | Purpose |
|---|---|---|
| `00-remote-deploy.sh` | Host shell | Orchestrates all steps over SSH |
| `02-install-provider.sh` | CA VM, Client VM | Build LibOQS or SymCrypt + register OpenSSL provider |
| `03-build-ca.sh` | CA VM | Generate Root CA (ML-DSA-87) + Intermediate CA (ML-DSA-65) |
| `04-issue-server-cert.sh` | CA VM | Issue ML-DSA-65 server cert + configure Apache vhost on web VM |
| `05-verify-tls.sh` | CA VM | 8-check server-side verification suite |
| `06-client-verify.sh` | Client VM | Client-side TLS 1.3, chain trust, PQ key exchange, TLS 1.2 rejection |

### Azure-specific

| Script | Runs on | Purpose |
|---|---|---|
| `01-azure-infra.sh` | Local machine | Provision VMs, VNet, NSG, public IPs via `az` CLI |
| `cloud-init-ca.yml` | Injected at create | CA VM first-boot packages + directory setup |
| `cloud-init-web.yml` | Injected at create | Web VM first-boot: Apache + mod_ssl |
| `cloud-init-client.yml` | Injected at create | Client VM first-boot: Ubuntu desktop GUI (XFCE + xrdp + Firefox) + TLS test prerequisites |
| `99-teardown.sh` | Local machine | Delete entire Azure resource group |

### Hyper-V-specific

| Script | Runs on | Purpose |
|---|---|---|
| `01-hyperv-infra.ps1` | Hyper-V host | Create 3 VMs from base VHDX (differencing disks) + write `.deploy-state` |
| `99-teardown.ps1` | Hyper-V host | Remove VMs, disks, and optionally the virtual switch |

---

## Choosing a Deployment Path

**Use Azure if you:**
- Do not have a Hyper-V host available
- Want the fastest path from zero to a running environment
- Are evaluating PQ PKI for Azure-hosted production workloads
- Need to share access with a team via public IPs
- Are comfortable with ~$461/month for the test period

**Use Hyper-V if you:**
- Have a Windows machine with adequate RAM (≥32 GB recommended for 3 VMs)
- Need an air-gapped or isolated lab environment
- Do not have an Azure subscription
- Want to avoid ongoing cloud costs
- Are testing for an on-premises or private cloud deployment scenario

**Either path works for:**
- Validating ML-DSA/ML-KEM algorithm behavior
- Comparing LibOQS vs SymCrypt side by side
- End-to-end TLS 1.3 + PQ handshake verification
- Learning PQ PKI hierarchy design

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `cloud-init timeout` (Azure) | VM too small for SymCrypt build | Use `Standard_D4s_v5` — SymCrypt peaks ~8 GB RAM |
| VM gets no IP (Hyper-V) | Guest not fully booted, or switch misconfigured | Check Hyper-V Manager → Networking; confirm `Default Switch` IP range |
| `oqsprovider.so not found` | CMake/build failed | Re-run `02-install-provider.sh`; check `/var/log/pq-setup.log` |
| `symcryptprovider.so not found` | `git submodule update --init` not run | Script handles this, but check log if jitterentropy missing |
| `ML-DSA not listed` | Provider not activated | Verify `OPENSSL_CONF` points to correct `.cnf` file |
| `Server Temp Key: X25519` only | Apache lacks PQ provider env | Check `/etc/apache2/envvars.d/pq-openssl.conf` on web VM |
| Client verify: chain validation failed | Root CA not trusted on client | Copy cert to `/usr/local/share/ca-certificates/` and run `update-ca-certificates` |
| TLS 1.2 unexpectedly accepted | Apache `SSLProtocol` directive missing | Check vhost config — must include `-all +TLSv1.3` |

---

## References

- [NIST FIPS 203 — ML-KEM](https://csrc.nist.gov/publications/detail/fips/203/final)
- [NIST FIPS 204 — ML-DSA](https://csrc.nist.gov/publications/detail/fips/204/final)
- [Open Quantum Safe — liboqs](https://github.com/open-quantum-safe/liboqs)
- [Open Quantum Safe — oqs-provider](https://github.com/open-quantum-safe/oqs-provider)
- [Microsoft SymCrypt](https://github.com/microsoft/SymCrypt)
- [Microsoft SymCrypt-OpenSSL](https://github.com/microsoft/SymCrypt-OpenSSL)
- [Full Manual Setup Guide](40-Resources/pq-certificate-authority-ubuntu-2604.md)
