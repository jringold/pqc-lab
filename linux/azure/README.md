---
title: "Azure VM Deployment Scripts — Post-Quantum CA Testing"
type: resource
created: 2026-07-28
updated: 2026-08-01
tags: [azure, pki, post-quantum, ml-dsa, ml-kem, deployment, automation, bash, infrastructure, client]
sources:
  - "[[pq-certificate-authority-ubuntu-2604]]"
  - "https://learn.microsoft.com/en-us/cli/azure/"
  - "https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-cli"
status: growing
---

# Azure VM Deployment Scripts — Post-Quantum CA Testing

Scripts to automate provisioning and configuring Azure VMs for testing the [[pq-certificate-authority-ubuntu-2604|Post-Quantum CA guide]].

## Script Inventory

| Script | Runs on | Purpose |
|--------|---------|---------|
| `00-remote-deploy.sh` | Local machine | **Orchestrator** — calls all others in order |
| `01-azure-infra.sh` | Local machine | Provision VMs, VNet, NSG via Azure CLI |
| `cloud-init-ca.yml` | (injected into CA VM) | OS prep + directory structure |
| `cloud-init-web.yml` | (injected into Web VM) | Apache install |
| `cloud-init-client.yml` | (injected into Client VM) | Ubuntu desktop GUI + client OS prep for PQ TLS tests |
| `02-install-provider.sh` | CA VM | Build LibOQS or SymCrypt provider |
| `03-build-ca.sh` | CA VM | Create Root CA + Intermediate CA hierarchy |
| `04-issue-server-cert.sh` | CA VM | Issue server cert, push to web VM, configure Apache |
| `05-verify-tls.sh` | CA VM | 8-check verification suite (PQ TLS, chain, HSTS) |
| `06-client-verify.sh` | Client VM | Client-side TLS 1.3 negotiation + PQ key exchange checks |
| `99-teardown.sh` | Local machine | Delete Azure resource group |

## Architecture Deployed

```
                        ┌─────────────────────┐
Local Machine           │    Azure (eastus)     │
  az CLI  ──────────►   │  Resource Group      │
  SSH/SCP ──────────►   │                      │
                        │  VNet 10.0.0.0/16     │
                        │  ┌────────────────┐  │
                        │  │ mgmt-subnet    │  │
                        │  │ 10.0.1.0/24    │  │
                        │  │  pq-ca-vm      │  │
                        │  │  ML-DSA-87 CA  │  │
                        │  └───────┬────────┘  │
                        │          │ SCP certs   │
                        │  ┌───────▼────────┐  │
                        │  │ web-subnet     │  │
                        │  │ 10.0.2.0/24    │  │
                        │  │  pq-web-vm     │  │
                        │  │  Apache+ML-KEM │  │
                        │  └────────────────┘  │
                        │  ┌────────────────┐  │
                        │  │ client-subnet  │  │
                        │  │ 10.0.3.0/24    │  │
                        │  │ pq-client-vm   │  │
                        │  │ Ubuntu Desktop │  │
                        │  │ browser client │  │
                        │  └────────────────┘  │
                        └──────────────────────┘
```

## Prerequisites

On your **local machine**:
- Azure CLI >= 2.60  
  `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`
- Logged in to Azure:  
  `az login`
- `jq` installed:  
  `sudo apt install jq`
- SSH key pair (scripts use `~/.ssh/id_rsa` by default)

## Quickstart

### 1. Clone / copy scripts

All scripts are in `40-Resources/pq-ca-azure/` in this vault.

### 2. Set environment variables

```bash
# Required
export PROVIDER=liboqs        # or: symcrypt
export ADMIN_IP="$(curl -s https://ifconfig.me)/32"

# Optional — defaults shown
export PREFIX=pq-ca
export REGION=eastus
export VM_SIZE=Standard_D4s_v5
export ORG_NAME="TestOrg"
export ORG_COUNTRY="US"
export ORG_STATE="Washington"
```

> ⚠️ `Standard_D4s_v5` (4 vCPU / 16 GB) is the minimum recommended size.  
> SymCrypt builds require ~8 GB RAM during compilation. Do not use `Standard_B2s`.

### 3. Provision infrastructure

```bash
chmod +x 01-azure-infra.sh
./01-azure-infra.sh
```

Output: creates `.deploy-state` with VM IPs and settings.

### 4. Run full deployment

```bash
chmod +x 00-remote-deploy.sh
./00-remote-deploy.sh
```

This:
1. Waits for cloud-init to finish on CA, Web, and Client VMs (~5 min for LibOQS, ~15 min for SymCrypt)
2. Builds the PQ provider on the CA VM
3. Creates the Root CA (ML-DSA-87) and Intermediate CA (ML-DSA-65)
4. Issues an ML-DSA-65 server cert for the web VM's IP address
5. Pushes the cert + provider to the web VM and restarts Apache
6. Runs 8 automated TLS verification tests
7. Builds the same PQ provider on the client VM
8. Trusts the Root CA on the client VM
9. Runs client-side TLS verification (TLS 1.3 + PQ key exchange)

Expected final output:
```
══ Step 6: Run PQ TLS verification ══
  ✓ PASS  Port 443 is reachable on <WEB_IP>
  ✓ PASS  TLS handshake succeeded and cert chain verified
  ✓ PASS  Server cert uses ML-DSA: id-ml-dsa-65
  ✓ PASS  TLS 1.3 negotiated
  ✓ PASS  PQ key exchange confirmed: Server Temp Key: X25519_MLKEM768, 256 bits
  ✓ PASS  Full chain validates to provided Root CA
  ✓ PASS  HTTP redirects to HTTPS (HTTP 301)
  ✓ PASS  HSTS header present: Strict-Transport-Security: max-age=63072000...

RESULTS: 8/8 passed, 0 failed, 0 skipped
```

## Step-by-Step (Manual)

Use this if you prefer to run each step individually or need to debug.

### Step 1 — Provision VMs

```bash
export PROVIDER=liboqs
export ADMIN_IP="$(curl -s https://ifconfig.me)/32"
./01-azure-infra.sh
source .deploy-state
```

### Step 2 — Install PQ provider

```bash
scp 02-install-provider.sh ${ADMIN_USER}@${CA_IP}:/tmp/
ssh ${ADMIN_USER}@${CA_IP} \
  "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
```

Monitor progress:
```bash
ssh ${ADMIN_USER}@${CA_IP} "tail -f /var/log/pq-setup.log"
```

### Step 3 — Build CA hierarchy

```bash
scp 03-build-ca.sh ${ADMIN_USER}@${CA_IP}:/tmp/
ssh ${ADMIN_USER}@${CA_IP} \
  "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/03-build-ca.sh"
```

### Step 4 — Issue server cert and deploy to Apache

```bash
scp 04-issue-server-cert.sh ${ADMIN_USER}@${CA_IP}:/tmp/
ssh ${ADMIN_USER}@${CA_IP} \
  "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/04-issue-server-cert.sh \
    --domain ${WEB_IP} \
    --web-ip  ${WEB_IP} \
    --web-user ${ADMIN_USER}"
```

### Step 5 — Verify from CA VM

```bash
scp 05-verify-tls.sh ${ADMIN_USER}@${CA_IP}:/tmp/
ssh ${ADMIN_USER}@${CA_IP} \
  "PQ_PROVIDER=${PROVIDER} bash /tmp/05-verify-tls.sh \
    --target ${WEB_IP} \
    --ca-cert /opt/pq-ca/root-ca/certs/root-ca.cert.pem"
```

### Step 6 — Install provider on client VM

```bash
scp 02-install-provider.sh ${ADMIN_USER}@${CLIENT_IP}:/tmp/
ssh ${ADMIN_USER}@${CLIENT_IP} \
  "sudo mkdir -p /opt/pq-ca /opt/pq-ca-setup && \
   sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
```

### Step 7 — Trust Root CA on client VM

```bash
scp ${ADMIN_USER}@${CA_IP}:/opt/pq-ca/root-ca/certs/root-ca.cert.pem /tmp/pq-root-ca.crt
scp /tmp/pq-root-ca.crt ${ADMIN_USER}@${CLIENT_IP}:/tmp/pq-root-ca.crt
ssh ${ADMIN_USER}@${CLIENT_IP} \
  "sudo cp /tmp/pq-root-ca.crt /usr/local/share/ca-certificates/pq-root-ca.crt && \
   sudo update-ca-certificates"
```

### Step 8 — Verify TLS negotiation from client VM

```bash
scp 06-client-verify.sh ${ADMIN_USER}@${CLIENT_IP}:/tmp/
ssh ${ADMIN_USER}@${CLIENT_IP} \
  "chmod +x /tmp/06-client-verify.sh && \
   PQ_PROVIDER=${PROVIDER} bash /tmp/06-client-verify.sh \
     --target ${WEB_IP} \
     --ca-cert /usr/local/share/ca-certificates/pq-root-ca.crt"
```

### Step 9 — Open the desktop GUI

Use your RDP client to connect to the client VM on port 3389:

```bash
# Windows: mstsc /v:${CLIENT_IP}
# Linux:   xfreerdp /v:${CLIENT_IP}
```

Log in with the Azure VM admin username and the local password you configured. The session starts XFCE, with Firefox available for browser-based PQC inspection.

## Using a Custom Domain Name

By default, `00-remote-deploy.sh` uses the web VM's public IP address as the domain,
which generates an IP-SAN certificate. For a proper FQDN:

1. Point your DNS to `${WEB_IP}` (A record)
2. Set `DOMAIN=your.hostname.example.com` before running `00-remote-deploy.sh`

The certificate's SAN will include both `DNS.1=your.hostname.example.com` and
`DNS.2=www.your.hostname.example.com`.

## Switching Providers After Deployment

To swap from LibOQS to SymCrypt (or vice versa) on an existing VM:

```bash
ssh ${ADMIN_USER}@${CA_IP} "sudo PQ_PROVIDER=symcrypt bash /tmp/02-install-provider.sh"
# Then re-run 03 and 04 — they pick up the new OPENSSL_CONF
```

The CA directory (`/opt/pq-ca`) is preserved; re-running `03-build-ca.sh` will
skip the key generation if certs already exist and only regenerate if you first
delete the existing files.

## Teardown

```bash
./99-teardown.sh
```

This deletes the entire resource group (VMs, VNet, NSG, public IPs, NICs, disks).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `cloud-init` timeout | VM too small (SymCrypt build OOM) | Use `Standard_D4s_v5` or larger |
| `oqsprovider.so not found` | cmake did not find liboqs | Re-run `02-install-provider.sh`; check `/var/log/pq-setup.log` |
| `symcryptprovider.so not found` | SymCrypt build failed | Check `python3 scripts/build.py` output in log; ensure `git submodule update --init` ran |
| `ML-DSA not listed` | Provider not activated | Verify `OPENSSL_CONF` points to correct `.cnf` file |
| `Server Temp Key: X25519` (no MLKEM) | Apache doesn't have PQ provider | Check `/etc/apache2/envvars.d/pq-openssl.conf` exists on web VM |
| Client verify fails chain validation | Root CA not trusted on client | Re-copy cert to `/usr/local/share/ca-certificates/` and run `update-ca-certificates` |
| `Verification: FAILED` in s_client | Root CA not trusted | Pass `-CAfile /opt/pq-ca/root-ca/certs/root-ca.cert.pem` explicitly |
| Port 443 unreachable | NSG rule missing | Check `ADMIN_IP` was correct; re-run `01-azure-infra.sh` |

## Cost Estimate

| Resource | SKU | Approx. monthly cost |
|----------|-----|---------------------|
| CA VM (Standard_D4s_v5) | 4 vCPU / 16 GB | ~$140/mo |
| Web VM (Standard_D4s_v5) | 4 vCPU / 16 GB | ~$140/mo |
| Client VM (Standard_D4s_v5) | 4 vCPU / 16 GB | ~$140/mo |
| 3× Public IPs (Standard) | Static | ~$11/mo |
| OS Disks (Premium SSD P10) | 128 GB | ~$20/mo |
| **Total** | | **~$451/mo** |

> 💡 For testing, **deallocate VMs** when not in use (`az vm deallocate`).
> You only pay for storage while deallocated. Restart with `az vm start`.

## Related Notes

- [[pq-certificate-authority-ubuntu-2604]] — Full manual setup guide
- [[pq-certificate-authority]] — PowerPoint slide deck
