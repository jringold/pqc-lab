---
title: "Hyper-V Deployment Scripts — Post-Quantum CA Testing"
type: resource
created: 2026-08-01
updated: 2026-08-01
tags: [hyper-v, pki, post-quantum, ml-dsa, ml-kem, deployment, automation, powershell, bash]
sources:
  - "[[pq-certificate-authority-ubuntu-2604]]"
  - "[[pq-ca-azure/README]]"
  - "https://learn.microsoft.com/windows-server/virtualization/hyper-v/"
status: growing
---

# Hyper-V Deployment Scripts — Post-Quantum CA Testing

This is the Hyper-V equivalent of the Azure automation flow. It provisions **three Ubuntu 26.04 VMs** on Hyper-V and runs the same PQ PKI build/deploy/verify pipeline:

- `pq-hv-ca-vm` (Certificate Authority)
- `pq-hv-web-vm` (Apache TLS endpoint)
- `pq-hv-client-vm` (independent TLS client validation)

## Script inventory

| Script | Runs on | Purpose |
|---|---|---|
| `01-hyperv-infra.ps1` | Hyper-V host | Creates 3 VMs from Ubuntu template VHDX and writes `.deploy-state` |
| `00-remote-deploy.sh` | Host shell (WSL/Git Bash/Linux) | Orchestrates CA build, cert issue, web deploy, client trust + validation |
| `02-install-provider.sh` | CA VM + Client VM | Build/install LibOQS or SymCrypt provider |
| `03-build-ca.sh` | CA VM | Build Root + Intermediate CA |
| `04-issue-server-cert.sh` | CA VM | Issue server cert, deploy Apache TLS config to web VM |
| `05-verify-tls.sh` | CA VM | Server-side 8-check verification |
| `06-client-verify.sh` | Client VM | Client-side TLS 1.3 + PQ negotiation verification |
| `99-teardown.ps1` | Hyper-V host | Deletes VMs and VM storage |

## Prerequisites

1. Hyper-V enabled on Windows host.
2. Ubuntu 26.04 template VHDX prepared with:
   - SSH server enabled
   - a login user (default in scripts: `azureuser`)
   - your SSH public key in `~/.ssh/authorized_keys`
3. A virtual switch available (`Default Switch` works, or create your own external switch).
4. A shell with `ssh` and `scp` available (WSL or Git Bash recommended).

## Quickstart

### 1) Provision VMs on Hyper-V

Run in PowerShell (Admin):

```powershell
cd C:\Users\jaringol\ObsidianVault\40-Resources\pq-ca-hyperv

.\01-hyperv-infra.ps1 `
  -BaseVhdx "C:\HyperV\BaseImages\ubuntu-26.04-template.vhdx" `
  -SwitchName "Default Switch" `
  -Prefix "pq-hv" `
  -Provider "liboqs" `
  -AdminUser "azureuser"
```

This writes `.deploy-state` with:

- `CA_IP`
- `WEB_IP`
- `CLIENT_IP`
- `ADMIN_USER`
- `PROVIDER`

### 2) Run end-to-end deployment

Run from WSL/Git Bash:

```bash
cd /mnt/c/Users/jaringol/ObsidianVault/40-Resources/pq-ca-hyperv
chmod +x 00-remote-deploy.sh
./00-remote-deploy.sh
```

The orchestrator performs:

1. SSH readiness checks on CA/Web/Client VMs
2. Provider install on CA VM
3. CA hierarchy build
4. Server cert issue + Apache TLS deployment
5. `05-verify-tls.sh` from CA VM
6. Provider install on client VM
7. Root CA trust install on client VM
8. `06-client-verify.sh` from client VM (TLS 1.3 + PQ KEX + TLS 1.2 reject)

## Switching providers

Set provider in `.deploy-state` by re-running infra or overriding env:

```bash
PROVIDER=symcrypt ./00-remote-deploy.sh
```

## Notes

- As with Azure, **ML-DSA is for cert keys**, **ML-KEM is for TLS key exchange groups**.
- SymCrypt builds are heavier; use adequate VM sizing.
- If your VMs use hostnames, pass `DOMAIN=your.host.name` to `00-remote-deploy.sh`.

## Teardown

PowerShell (Admin):

```powershell
.\99-teardown.ps1
```

To also remove the switch (when managed solely for this lab):

```powershell
.\99-teardown.ps1 -RemoveSwitch
```
