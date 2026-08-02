# PQC PKI Lab on Hyper-V (Windows Server 2025 GA + KB5099536 or vNext 29550+)

> **WARNING** These files contain "Generic passwords" as placeholders, please be smart
> and change them while you are setting up your test labs. I went through and did a
> search and replace with something "generic", these passwords are not used in any
> deployment, not even my own lab.

This package provides a **Hyper-V alternative** to the Azure deployment flow.  
It builds the same PKI topology for testing:

- `dc01` (Domain Controller / DNS)
- `rootca` (Standalone Root CA, ML-DSA-87)
- `issuingca` (Enterprise Issuing CA, ML-DSA-65)
- `webserver01` (IIS web server with ML-DSA cert + ML-KEM TLS key exchange)
- `win11client` **(NEW)** (Windows 11 GA 24H2 + KB5101650 — ML-KEM enabled, Edge DevTools verification)

## Prerequisites

1. Hyper-V enabled on the host (Windows 10/11 Pro/Enterprise or Server).
2. A prepared **Server base image** at `BaseVhdPath` in `00-variables.ps1`:
   - Windows Server 2025 GA + KB5099536 (build 26100.33158+) **or** Windows Server vNext build 29550+.
   - Sysprepped or cloned, local Administrator password set to `LocalAdminPasswordPlain`.
- **Windows 11 ISO — build 26100.8524+ with KB5101650 (GA Win11 24H2/25H2)**
   - As of the July 14, 2026 security updates, **Insider Preview is no longer required** for ML-KEM TLS.
   - GA Win11 24H2/25H2 with KB5101650 (production) or KB5089573 (preview) is sufficient.
   - Win11 26H1 GA with KB5095091 also works.
   - Win11 Insider Preview build 26100.8514+ remains valid (original minimum, still works).
   - Sysprepped or cloned, local Administrator password matching `LocalAdminPasswordPlain`.
   - **Can be skipped** — the scripts detect a missing image and skip the client VM gracefully.
4. Host PowerShell run as Administrator.
5. Enough local resources (recommended minimum): 5 VMs × 2 vCPU × 4–8 GB RAM.

## Important PQC constraints

- ML-DSA is **signature-only** for cert operations.
- ML-KEM is for **TLS key exchange**, not cert public keys.
- ML-KEM groups must be explicitly enabled (`Enable-TlsEccCurve`) on **both** server and client.
- TLS 1.3 is required for ML-KEM hybrid groups.
- **Win11 client build (updated July 14, 2026):** GA Win11 24H2/25H2 + KB5101650 (build 26100.8524+) is
  now sufficient for ML-KEM. Insider Preview is no longer required for the client ML-KEM piece.
  Win11 26H1 + KB5095091 also works. Insider Preview 26100.8514+ remains valid.
- **Server ML-KEM:** GA Windows Server 2025 + KB5099536 (July 14, 2026) now supports ML-KEM hybrid TLS.
  ML-DSA certificate issuance still requires KB5087539 (May 2026) or vNext 29550+.

## Script order

1. `00-variables.ps1` (edit first — set `DeploymentMode`, server image paths, and `Win11BaseVhdPath`)
2. `01-prereq-check.ps1`
3. `02-new-lab-vms.ps1`
4. `00-verify-patches.ps1` (confirm required server build/KB baseline before AD CS setup)
5. `03-config-dc.ps1`
6. `04-config-rootca.ps1`
7. `05-config-issuingca.ps1`
8. `06-config-webserver.ps1`
9. `07-enable-mlkem-tls.ps1`
10. `08-verify.ps1`
11. `09-config-win11-client.ps1` ← **Win11 client — ML-KEM + Edge PQC verification**

Cleanup:
- `99-cleanup.ps1`

## Notes on the base images

### Server base image
Should be a clean Windows Server 2025 GA + KB5099536 image, or a clean vNext install, sysprepped or otherwise consistent for differencing disks:
- PowerShell enabled
- Hyper-V integration services active
- Local Administrator credentials matching `00-variables.ps1`

### Win11 client base image
Same requirements, different OS:
- Win11 24H2 GA + KB5101650 (build 26100.8524+) — **Insider Preview no longer required** as of July 14, 2026
- Win11 26H1 GA + KB5095091 also works
- Win11 Insider Preview build 26100.8514+ remains valid (original minimum)
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
