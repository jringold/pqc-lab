# PQC PKI Lab — Credentials Inventory

> ⚠️ **Change all default values before deploying.** These are lab defaults only.
> Never use these passwords in a production or internet-exposed environment.
>
> **Single source of truth:** All passwords are defined in the `00-variables.ps1`
> file for each deployment path. Edit that file — scripts read from it automatically.

---

## Azure Path (`pqc-azure-deploy/00-variables.ps1`)

| Variable | Default Value | Purpose | Used In |
|----------|--------------|---------|---------|
| `$ADMIN_PASS` | `P@ssw0rd-PQCLab2026!` | Local Administrator on all Azure VMs | `01-deploy-infrastructure.ps1` (VM creation), `04-config-issuingca.ps1`, `05-config-tls-template.ps1`, `08-config-win11-client.ps1` |
| `$SAFE_MODE_PASS` | `P@ssw0rd-DSRM2026!` | AD Directory Services Restore Mode (DSRM) | `02-config-dc.ps1` |
| `$SVC_CA_PASS` | `P@ssw0rd-SvcCA2026!` | `svc-ca-enroll` AD service account | `02-config-dc.ps1` |

---

## Hyper-V Path (`pqc-hyperv-deploy/00-variables.ps1`)

| Variable | Default Value | Purpose | Used In |
|----------|--------------|---------|---------|
| `$LocalAdminPasswordPlain` | `P@ssw0rd-LocalAdmin-2026!` | Local Administrator on all Hyper-V VMs (pre-domain-join) | `05-config-issuingca.ps1`, `06-config-webserver.ps1`, `09-config-win11-client.ps1`, `00-common.ps1` |
| `$SafeModePasswordPlain` | `P@ssw0rd-DSRM-2026!` | AD Directory Services Restore Mode (DSRM) | `03-config-dc.ps1` |
| `$SvcCaPasswordPlain` | `P@ssw0rd-SvcCA-2026!` | `svc-ca-enroll` AD service account | `03-config-dc.ps1` |

---

## Account Reference

| Account | Type | Domain | Default Password Variable |
|---------|------|--------|--------------------------|
| `labadmin` (Azure) | Local Administrator | N/A (pre-join) / `PQCLAB\labadmin` (post-join) | `$ADMIN_PASS` |
| `Administrator` (Hyper-V) | Local Administrator | N/A (pre-join) / `PQCLAB\Administrator` (post-join) | `$LocalAdminPasswordPlain` |
| DSRM recovery account | AD recovery | `pqclab.local` | `$SAFE_MODE_PASS` / `$SafeModePasswordPlain` |
| `svc-ca-enroll` | AD service account | `pqclab.local` | `$SVC_CA_PASS` / `$SvcCaPasswordPlain` |

---

## Notes

- **DSRM password** is set once during `Install-ADDSForest` and cannot be changed through normal means. To change it post-promotion: `ntdsutil "set dsrm password" "reset password on server null" quit quit`.
- **`svc-ca-enroll`** is created with `PasswordNeverExpires = $true`. For production-aligned labs, set an expiry and rotate regularly.
- **VM local admin** on Hyper-V VMs must match `$LocalAdminPasswordPlain` **before** running scripts — it is set during Sysprep/OOBE on the gold VHDX.
- The manual install guide (`pqc-manual-install-guide.md`) uses these same default values as examples. Update those examples if you change the defaults here.
