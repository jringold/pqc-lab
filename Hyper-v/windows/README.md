# PQC PKI Lab on Hyper-V (Windows Server vNext 29550+)

This package provides a **Hyper-V alternative** to the Azure deployment flow.  
It builds the same PKI topology for testing:

- `dc01` (Domain Controller / DNS)
- `rootca` (Standalone Root CA, ML-DSA-87)
- `issuingca` (Enterprise Issuing CA, ML-DSA-65)
- `webserver01` (IIS web server with ML-DSA cert + ML-KEM TLS key exchange)

## Prerequisites

1. Hyper-V enabled on the host.
2. A prepared base image at `BaseVhdPath` in `00-variables.ps1`:
   - Windows Server vNext Insider Preview build 29550+.
   - Local Administrator password set to `LocalAdminPasswordPlain` (or update variable).
3. Host PowerShell run as Administrator.
4. Enough local resources (recommended minimum): 4 VMs x 2 vCPU x 4-8 GB RAM.

## Important PQC constraints

- ML-DSA is **signature-only** for cert operations.
- ML-KEM is for **TLS key exchange**, not cert public keys.
- ML-KEM groups must be explicitly enabled (`Enable-TlsEccCurve`).
- TLS 1.3 is required for ML-KEM hybrid groups.

## Script order

1. `00-variables.ps1` (edit first)
2. `01-prereq-check.ps1`
3. `02-new-lab-vms.ps1`
4. `03-config-dc.ps1`
5. `04-config-rootca.ps1`
6. `05-config-issuingca.ps1`
7. `06-config-webserver.ps1`
8. `07-enable-mlkem-tls.ps1`
9. `08-verify.ps1`

Cleanup:
- `99-cleanup.ps1`

## Notes on the base image

The base image should be a clean vNext image (sysprepped or otherwise consistent for cloning) with:

- PowerShell enabled
- Hyper-V integration services active
- Local Administrator credentials matching `00-variables.ps1`

## Validation target

After `08-verify.ps1`, expected state:

- Root CA and Issuing CA chain operational
- Web server has ML-DSA certificate
- TLS stack exposes `x25519_mlkem768` at highest priority
- HTTPS endpoint responds on `https://webserver01.pqclab.local`

