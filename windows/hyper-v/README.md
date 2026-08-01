# PQC PKI Lab on Hyper-V (Windows Server vNext 29550+)

This package provides a **Hyper-V alternative** to the Azure deployment flow.  
It builds the same PKI topology for testing:

- `dc01` (Domain Controller / DNS)
- `rootca` (Standalone Root CA, ML-DSA-87)
- `issuingca` (Enterprise Issuing CA, ML-DSA-65)
- `webserver01` (IIS web server with ML-DSA cert + ML-KEM TLS key exchange)
- `win11client` **(NEW)** (Windows 11 Insider Preview — ML-KEM enabled, Edge DevTools verification)

## Prerequisites

1. Hyper-V enabled on the host (Windows 10/11 Pro/Enterprise or Server).
2. A prepared **Server base image** at `BaseVhdPath` in `00-variables.ps1`:
   - Windows Server vNext Insider Preview build 29550+.
   - Sysprepped or cloned, local Administrator password set to `LocalAdminPasswordPlain`.
3. A prepared **Win11 client base image** at `Win11BaseVhdPath` in `00-variables.ps1`:
   - Windows 11 Insider Preview build 26100.8514+ (Dev or Beta channel).
   - Same preparation steps: local Administrator password matching `LocalAdminPasswordPlain`.
   - **Can be skipped** — the scripts detect a missing image and skip the client VM gracefully.
4. Host PowerShell run as Administrator.
5. Enough local resources (recommended minimum): 5 VMs × 2 vCPU × 4–8 GB RAM.

## Important PQC constraints

- ML-DSA is **signature-only** for cert operations.
- ML-KEM is for **TLS key exchange**, not cert public keys.
- ML-KEM groups must be explicitly enabled (`Enable-TlsEccCurve`) on **both** server and client.
- TLS 1.3 is required for ML-KEM hybrid groups.
- Win11 client build must be **26100.8514 or later** for ML-KEM support.

## Script order

1. `00-variables.ps1` (edit first — update both `BaseVhdPath` and `Win11BaseVhdPath`)
2. `01-prereq-check.ps1`
3. `02-new-lab-vms.ps1`
4. `03-config-dc.ps1`
5. `04-config-rootca.ps1`
6. `05-config-issuingca.ps1`
7. `06-config-webserver.ps1`
8. `07-enable-mlkem-tls.ps1`
9. `08-verify.ps1`
10. `09-config-win11-client.ps1` ← **Win11 client — ML-KEM + Edge PQC verification**

Cleanup:
- `99-cleanup.ps1`

## Notes on the base images

### Server vNext base image
Should be a clean vNext install (sysprepped or otherwise consistent for differencing disks):
- PowerShell enabled
- Hyper-V integration services active
- Local Administrator credentials matching `00-variables.ps1`

### Win11 Insider Preview client base image
Same requirements, different OS:
- Win11 Insider Preview, build 26100.8514+
- Microsoft Edge pre-installed (ships with Win11 by default)
- Local Administrator credentials matching `LocalAdminPasswordPlain`

If `Win11BaseVhdPath` doesn't exist when `02-new-lab-vms.ps1` runs, the client VM is
skipped and a warning is printed. You can create it later and run `09-config-win11-client.ps1`
independently once the rest of the lab is up.

## Validation target

After `09-config-win11-client.ps1`, expected state from the client VM:

- Root CA trusted (via domain GPO)
- TLS handshake to `https://webserver01.pqclab.local` succeeds with:
  - Protocol: **TLS 1.3**
  - Cert signature: **id-ML-DSA-65** (chain to id-ML-DSA-87 Root)
  - Key exchange: **x25519_mlkem768** (visible in Edge F12 → Security tab)

