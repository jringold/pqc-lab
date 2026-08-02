---
title: "PQC PKI CA Lab — Credential & Secret Inventory"
type: resource
created: 2026-08-02
updated: 2026-08-02
tags: [pki, post-quantum, security, credentials, passwords, secrets, lab]
sources: ["internal"]
status: evergreen
---

# PQC PKI CA Lab — Credential & Secret Inventory

This document catalogs every credential, secret, key, and password used across the PQC PKI CA
test lab (both Azure and Hyper-V deployments). It is intended to support security review,
pre-deployment checklist completion, and ongoing lab maintenance.

> ⚠️ **This lab is a test environment.** None of the credentials below should be reused in
> production. All private keys in the lab are intentionally unencrypted to support automation.
> See the "Production Hardening" section at the end for recommended changes.

---

## Summary Table

| Credential | Type | Where set | Hardcoded? | Default value | Used by |
|-----------|------|-----------|------------|---------------|---------|
| `ADMIN_PASSWORD` | VM login password | Environment variable | No | *(empty — required)* | Azure client VM RDP |
| SSH private key (`SSH_KEY`) | SSH key pair | Environment variable | No | `~/.ssh/id_rsa` | Operator → all VMs; CA → Web SCP |
| Root CA private key | PEM (unencrypted) | `/opt/pq-ca/root-ca/private/root-ca.key.pem` | N/A | Generated at runtime | CA VM only |
| Intermediate CA private key | PEM (unencrypted) | `/opt/pq-ca/intermediate-ca/private/intermediate-ca.key.pem` | N/A | Generated at runtime | CA VM only |
| Server private key | PEM (unencrypted) | `/opt/pq-ca/intermediate-ca/private/<DOMAIN>.key.pem` | N/A | Generated at runtime | Copied to Web VM |
| Example placeholder password | Documentation only | README / script comments | Yes (example only) | `ChangeMe-Strong-Passphrase-123!` | Never used by scripts |

---

## Detailed Entries

### 1. `ADMIN_PASSWORD` — Azure Client VM RDP Password

| Attribute | Value |
|-----------|-------|
| **Purpose** | Password-based login to the Ubuntu desktop (XFCE) client VM over RDP (port 3389) |
| **Type** | String password |
| **Set by** | Operator — must be exported as an environment variable before running `01-azure-infra.sh` |
| **Default** | Empty — the script exits with an error if not provided |
| **Passed to** | `az vm create --admin-password "$ADMIN_PASSWORD"` |
| **Applies to** | Azure deployment only (`pq-ca-azure/`) — Hyper-V does not use this |
| **Hardcoded** | No |

**Files that reference it:**

| File | Line | Nature of reference |
|------|------|---------------------|
| `pq-ca-azure/01-azure-infra.sh` | L20 | Comment: usage example with placeholder value |
| `pq-ca-azure/01-azure-infra.sh` | L39 | `ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"` — reads from env, empty default |
| `pq-ca-azure/01-azure-infra.sh` | L74 | Guard: `[[ -n "$ADMIN_PASSWORD" ]] \|\| error "..."` |
| `pq-ca-azure/01-azure-infra.sh` | L276 | `az vm create --admin-password "$ADMIN_PASSWORD"` — actual use |
| `pq-ca-azure/README.md` | L88 | Example quickstart showing placeholder |
| `pq-ca-github-readme.md` | L97 | Same example placeholder |

**Placeholder value in documentation:** `ChangeMe-Strong-Passphrase-123!`

> ⚠️ This placeholder appears in comments and README examples only. The scripts never assign
> it as a default — if you run `01-azure-infra.sh` without setting `ADMIN_PASSWORD`, the
> script fails immediately. You must supply your own value.

**Recommended practice:** Generate a random strong password before each deployment:

```bash
export ADMIN_PASSWORD="$(openssl rand -base64 18)"
echo "Save this: $ADMIN_PASSWORD"
```

---

### 2. SSH Private Key (`SSH_KEY`)

| Attribute | Value |
|-----------|-------|
| **Purpose** | Key-based SSH authentication for: operator to all VMs; CA VM to Web VM (SCP cert transfer) |
| **Type** | SSH private key file path |
| **Set by** | Operator — exported as `SSH_KEY` environment variable |
| **Default** | `~/.ssh/id_rsa` |
| **Applies to** | Both Azure and Hyper-V deployments |
| **Hardcoded** | No |

**Files that reference it:**

| File | Line(s) | Nature of reference |
|------|---------|---------------------|
| `pq-ca-azure/00-remote-deploy.sh` | `SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"` | Reads from env with fallback default |
| `pq-ca-azure/00-remote-deploy.sh` | ~L136–148 | Stages key to `/tmp/pq-web-ssh-key` on CA VM for cert push step |
| `pq-ca-azure/04-issue-server-cert.sh` | L43 | `SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"` |
| `pq-ca-azure/04-issue-server-cert.sh` | L57 | Guard: `[[ -f "$SSH_KEY" ]] \|\| error "SSH key not found"` |
| `pq-ca-azure/04-issue-server-cert.sh` | L208 | Used in `-i ${SSH_KEY}` SCP/SSH options |
| `pq-ca-azure/README.md` | — | Documents `export SSH_KEY=~/.ssh/id_rsa` |
| `pq-ca-hyperv/00-remote-deploy.sh` | Same pattern as Azure | Same staging behaviour |
| `pq-ca-hyperv/04-issue-server-cert.sh` | Same as Azure | Identical script |

**Temporary staging:** `00-remote-deploy.sh` copies the private key to the CA VM at
`/tmp/pq-web-ssh-key` so that `04-issue-server-cert.sh` can use it to SCP certs to the Web VM.
A `trap ... EXIT` in the orchestrator removes this file on exit (clean or error).

> ⚠️ The private key is briefly present on the CA VM at `/tmp/pq-web-ssh-key`. If the
> deployment crashes before the trap fires, verify the file has been removed manually:
> `ssh <CA_VM> "ls -la /tmp/pq-web-ssh-key"` and delete if present.

---

### 3. Root CA Private Key

| Attribute | Value |
|-----------|-------|
| **Purpose** | Signs the Intermediate CA certificate. Most sensitive key in the lab. |
| **Type** | Unencrypted PEM file (`ml-dsa-87`) |
| **Location (CA VM)** | `/opt/pq-ca/root-ca/private/root-ca.key.pem` |
| **Permissions** | `400` (owner read-only) |
| **Passphrase** | None — unencrypted for automation |
| **Generated by** | `03-build-ca.sh` → `openssl genpkey -algorithm ml-dsa-87` |
| **Algorithm** | ML-DSA-87 (NIST FIPS 204 Level 5, ~AES-256 equivalent) |
| **Applies to** | Both Azure and Hyper-V (identical script) |

> ⚠️ In production this key must be generated on an HSM or air-gapped machine, encrypted with
> a strong passphrase, and stored offline after the Intermediate CA is signed.

---

### 4. Intermediate CA Private Key

| Attribute | Value |
|-----------|-------|
| **Purpose** | Signs all server certificates issued by the CA |
| **Type** | Unencrypted PEM file (`ml-dsa-65`) |
| **Location (CA VM)** | `/opt/pq-ca/intermediate-ca/private/intermediate-ca.key.pem` |
| **Permissions** | `400` (owner read-only) |
| **Passphrase** | None — unencrypted for automation |
| **Generated by** | `03-build-ca.sh` → `openssl genpkey -algorithm ml-dsa-65` |
| **Algorithm** | ML-DSA-65 (NIST FIPS 204 Level 3, ~AES-192 equivalent) |
| **Applies to** | Both Azure and Hyper-V |

---

### 5. Server Private Key

| Attribute | Value |
|-----------|-------|
| **Purpose** | TLS private key for the Apache HTTPS endpoint |
| **Type** | Unencrypted PEM file (`ml-dsa-65`) |
| **Location (CA VM — origin)** | `/opt/pq-ca/intermediate-ca/private/<DOMAIN>.key.pem` |
| **Location (Web VM — deployed)** | `/etc/ssl/private/<DOMAIN>.key.pem` |
| **Permissions on Web VM** | `600` (owner read-only) |
| **Passphrase** | None — Apache cannot prompt for a passphrase at startup without manual intervention |
| **Generated by** | `04-issue-server-cert.sh` → `openssl genpkey -algorithm ml-dsa-65` |
| **Algorithm** | ML-DSA-65 |
| **Applies to** | Both Azure and Hyper-V |

> ⚠️ The server key is transferred from the CA VM to the Web VM via SCP. It is in transit
> briefly over the internal VNet (Azure) or private Hyper-V switch. Verify that `/tmp/<DOMAIN>.key.pem`
> on the Web VM is removed after installation (the remote setup block in `04-issue-server-cert.sh`
> does not explicitly clean `/tmp` — this is a known minor gap).

---

### 6. Example Placeholder Password (Documentation Only)

| Attribute | Value |
|-----------|-------|
| **Value** | `ChangeMe-Strong-Passphrase-123!` |
| **Nature** | Illustrative placeholder — appears in script header comments and README examples only |
| **Used by scripts** | Never — it appears only in `# comment` lines and Markdown code blocks |
| **Risk** | If copy-pasted verbatim, this becomes the actual `ADMIN_PASSWORD` for the deployment |

**Exact locations:**

| File | Line | Text |
|------|------|------|
| `pq-ca-azure/01-azure-infra.sh` | L20 | `#   export ADMIN_PASSWORD='ChangeMe-Strong-Passphrase-123!'` |
| `pq-ca-azure/README.md` | L88 | `export ADMIN_PASSWORD='ChangeMe-Strong-Passphrase-123!'` |
| `pq-ca-github-readme.md` | L97 | `export ADMIN_PASSWORD='ChangeMe-Strong-Passphrase-123!'` |

---

## What Is NOT Present

The following credential types were scanned for and **not found** anywhere in the lab files:

| Type | Scan result |
|------|-------------|
| Hardcoded SSH passwords | Not found |
| Azure subscription IDs or tenant IDs | Not found |
| Azure service principal secrets / client secrets | Not found |
| API keys or tokens | Not found |
| Database passwords | Not found |
| Hyper-V VM passwords | Not found |
| Cloud-init user passwords | Not found — VMs use SSH key auth only |
| Apache BasicAuth passwords | Not found |
| OpenSSL passphrase-protected PEM keys | Not found (by design for automation) |
| `ConvertTo-SecureString` with literal values (PowerShell) | Not found |

---

## Production Hardening Recommendations

These items are intentionally skipped in the test lab for automation convenience. A production
deployment should address all of them.

| Item | Lab state | Production recommendation |
|------|-----------|--------------------------|
| Root CA key passphrase | Unencrypted | Add `-aes256` to `openssl genpkey`; store passphrase in HSM or secrets vault |
| Intermediate CA key passphrase | Unencrypted | Same as above |
| Server key passphrase | Unencrypted | Use `SSLPassPhraseDialog` in Apache or store in secrets manager |
| Root CA key location | Stays on the CA VM | Move to offline/air-gapped storage after signing the Intermediate CA |
| `ADMIN_PASSWORD` complexity | Placeholder in docs | Enforce minimum length/complexity; rotate after each lab session |
| SSH key for CA→Web transfer | Temporarily staged on CA VM at `/tmp/pq-web-ssh-key` | Use a dedicated deployment key with write-only access; revoke after use |
| Server key cleanup on Web VM | `/tmp/<DOMAIN>.key.pem` not explicitly removed | Add `sudo rm -f /tmp/<DOMAIN>.key.pem` after install in step 4.7 |
| Private key permissions on CA VM | `400` | Acceptable; consider adding `chattr +i` to prevent accidental overwrite |
