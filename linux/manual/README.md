---
title: "PQC PKI CA Lab — Manual Build Guide"
type: resource
created: 2026-08-02
updated: 2026-08-02
tags: [pki, post-quantum, ml-dsa, ml-kem, tls, apache, liboqs, symcrypt, ubuntu, manual-install]
sources:
  - "https://github.com/open-quantum-safe/liboqs"
  - "https://github.com/open-quantum-safe/oqs-provider"
  - "https://github.com/microsoft/SymCrypt"
  - "https://github.com/microsoft/SymCrypt-OpenSSL"
status: evergreen
---

# PQC PKI CA Lab — Manual Build Guide

> **WARNING** These files contain "Generic passwords" as placeholders, please be smart
> and change them while you are setting up your test labs. I went through and did a
> search and replace with something "generic", these passwords are not used in any
> deployment, not even my own lab.

This guide walks through building the Post-Quantum PKI CA lab entirely by hand, without using the automated scripts. Use it to:

- Understand every action the scripts perform
- Validate that a scripted deployment reached the correct end state
- Reproduce the environment on a platform not covered by the scripts

## Lab Architecture

Three Ubuntu 26.04 LTS VMs (or bare-metal machines) are required:

| Role | Hostname (example) | Purpose |
|------|-------------------|---------|
| CA VM | `pq-ca` | Root CA + Intermediate CA, holds all keys and scripts |
| Web VM | `pq-web` | Apache 2 HTTPS endpoint serving the PQ-signed certificate |
| Client VM | `pq-client` | Verification client; runs `openssl s_client` and `06-client-verify.sh` |

The CA VM issues all certificates. The Web VM only receives files pushed to it by the CA VM.
The Client VM only needs the Root CA certificate trusted and the PQ provider installed.

### Network requirements

| Port | Direction | Purpose |
|------|-----------|---------|
| 22 (TCP) | CA → Web, CA → Client, operator → all | SSH/SCP |
| 443 (TCP) | Client → Web, operator → Web | HTTPS |
| 80 (TCP) | Client → Web | HTTP redirect check (optional) |

---

## Part 0 — Common: Prepare all three VMs

Repeat these steps on **each** VM (CA, Web, Client) before continuing.

### 0.1 Fresh Ubuntu 26.04 LTS installation

Install Ubuntu 26.04 LTS with default settings. A minimal server install is sufficient for the CA
and Client VMs. The Web VM also needs only the server base; Apache is installed in Part 4.

Verify the OS:

```bash
lsb_release -a
# Expected: Ubuntu 26.04 LTS
```

### 0.2 Apply all updates

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### 0.3 Install common build dependencies

```bash
sudo apt install -y \
  build-essential cmake ninja-build git curl wget \
  libssl-dev python3 python3-pip python3-pytest \
  pkg-config gcc g++ ca-certificates jq
```

### 0.4 Verify OpenSSL version (must be 3.x)

```bash
openssl version
# Expected: OpenSSL 3.x.x ...
```

Ubuntu 26.04 ships OpenSSL 3.3+. The provider API required for post-quantum algorithms requires
OpenSSL 3.x. If you see 1.x, stop — the provider mechanism will not work.

### 0.5 Create the CA directory structure (CA VM only)

Run this only on the **CA VM**:

```bash
sudo mkdir -p /opt/pq-ca-setup
sudo mkdir -p /opt/pq-ca/{root-ca,intermediate-ca}
sudo mkdir -p /opt/pq-ca/root-ca/{certs,crl,newcerts,private,csr}
sudo mkdir -p /opt/pq-ca/intermediate-ca/{certs,crl,newcerts,private,csr}

sudo chmod 700 /opt/pq-ca/root-ca/private
sudo chmod 700 /opt/pq-ca/intermediate-ca/private

sudo touch /opt/pq-ca/root-ca/index.txt
sudo touch /opt/pq-ca/intermediate-ca/index.txt

echo 1000 | sudo tee /opt/pq-ca/root-ca/serial
echo 1000 | sudo tee /opt/pq-ca/intermediate-ca/serial
echo 1000 | sudo tee /opt/pq-ca/root-ca/crlnumber
echo 1000 | sudo tee /opt/pq-ca/intermediate-ca/crlnumber

sudo mkdir -p /usr/local/src
```

### 0.6 Set the provider environment variable (CA VM only)

Choose your provider and set it for the session. You must be consistent — do not mix providers
across steps on the same machine.

For **Option A — LibOQS**:

```bash
export PQ_PROVIDER=liboqs
export OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf
```

For **Option B — SymCrypt**:

```bash
export PQ_PROVIDER=symcrypt
export OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf
```

To make this persistent across SSH sessions, write the env file:

```bash
sudo tee /opt/pq-ca-setup/env.sh > /dev/null << EOF
export PQ_PROVIDER="${PQ_PROVIDER}"
export ORG_NAME="TestOrg"
export ORG_COUNTRY="US"
export ORG_STATE="Washington"
if [ "\$PQ_PROVIDER" = "liboqs" ]; then
  export OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf
else
  export OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf
fi
EOF

sudo tee /etc/profile.d/pq-provider.sh > /dev/null << EOF
export PQ_PROVIDER="${PQ_PROVIDER}"
if [ "\$PQ_PROVIDER" = "liboqs" ]; then
  export OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf
else
  export OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf
fi
EOF
```

---

## Part 1 — Option A: Build LibOQS + OQS-Provider (CA VM)

> Skip to Part 2 if you chose Option B (SymCrypt).

All commands in Part 1 run on the **CA VM** as root (or with `sudo bash`).

### A.1 Clone and build liboqs

```bash
sudo git clone -b main https://github.com/open-quantum-safe/liboqs.git \
  /usr/local/src/liboqs

sudo cmake -S /usr/local/src/liboqs -B /usr/local/src/liboqs/build \
  -GNinja \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_SHARED_LIBS=ON \
  -DOQS_USE_OPENSSL=ON \
  -DCMAKE_BUILD_TYPE=Release

sudo ninja -C /usr/local/src/liboqs/build
sudo ninja -C /usr/local/src/liboqs/build install
sudo ldconfig
```

Verify the shared library was installed:

```bash
ls /usr/local/lib/liboqs.so*
# Expected: /usr/local/lib/liboqs.so  /usr/local/lib/liboqs.so.X.Y.Z
```

Build time: approximately 3–5 minutes.

### A.2 Clone and build oqs-provider

```bash
sudo git clone https://github.com/open-quantum-safe/oqs-provider.git \
  /usr/local/src/oqs-provider

sudo cmake -S /usr/local/src/oqs-provider -B /usr/local/src/oqs-provider/build \
  -GNinja \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -Dliboqs_DIR=/usr/local/lib/cmake/liboqs

sudo ninja -C /usr/local/src/oqs-provider/build
sudo ninja -C /usr/local/src/oqs-provider/build install
sudo ldconfig
```

Verify the provider module:

```bash
ls /usr/local/lib/ossl-modules/oqsprovider.so
# Must exist
```

### A.3 Create the LibOQS OpenSSL provider configuration

Create `/opt/pq-ca/openssl-pq.cnf`:

```bash
sudo tee /opt/pq-ca/openssl-pq.cnf > /dev/null << 'EOF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default     = default_sect
oqsprovider = oqsprovider_sect

[default_sect]
activate = 1

[oqsprovider_sect]
module   = /usr/local/lib/ossl-modules/oqsprovider.so
activate = 1
EOF
```

### A.4 Verify ML-DSA and ML-KEM are available

```bash
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl list -signature-algorithms | grep -i ml-dsa
# Expected: ml-dsa-44  ml-dsa-65  ml-dsa-87

OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl list -kem-algorithms | grep -i ml-kem
# Expected: ml-kem-512  ml-kem-768  ml-kem-1024
```

If you see no output, the provider is not loading. Verify that `oqsprovider.so` exists at
`/usr/local/lib/ossl-modules/oqsprovider.so` and that the `module=` path in the `.cnf` matches.

---

## Part 2 — Option B: Build SymCrypt + SymCrypt-OpenSSL (CA VM)

> Skip to Part 3 if you completed Option A.

All commands in Part 2 run on the **CA VM** as root. SymCrypt requires more RAM during compilation
(peaks ~8 GB) and takes approximately 10–15 minutes to build. Use a VM with at least 16 GB RAM.

### B.1 Install SymCrypt build dependencies

```bash
sudo apt install -y cmake ninja-build python3 python3-pip \
  libssl-dev gcc g++ pkg-config
```

### B.2 Clone and build SymCrypt

```bash
sudo git clone https://github.com/microsoft/SymCrypt.git \
  /usr/local/src/SymCrypt

# Initialize the jitterentropy submodule (required for FIPS-compliant entropy)
sudo git -C /usr/local/src/SymCrypt submodule update --init

cd /usr/local/src/SymCrypt
sudo python3 scripts/build.py cmake release --arch amd64
```

After the build completes, install the shared library:

```bash
SYMCRYPT_SO=$(find /usr/local/src/SymCrypt/bin/release -name "libsymcrypt.so.*" | head -1)
echo "Found: $SYMCRYPT_SO"

sudo cp "$SYMCRYPT_SO" /usr/local/lib/
SONAME=$(basename "$SYMCRYPT_SO")
sudo ln -sf "/usr/local/lib/${SONAME}" /usr/local/lib/libsymcrypt.so
sudo ldconfig
```

Verify:

```bash
ls /usr/local/lib/libsymcrypt.so*
# Expected: libsymcrypt.so -> libsymcrypt.so.X.Y.Z.W
```

### B.3 Clone and build SymCrypt-OpenSSL

```bash
sudo git clone https://github.com/microsoft/SymCrypt-OpenSSL.git \
  /usr/local/src/SymCrypt-OpenSSL

sudo cmake -S /usr/local/src/SymCrypt-OpenSSL \
           -B /usr/local/src/SymCrypt-OpenSSL/build \
  -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DSYMCRYPT_ROOT=/usr/local/src/SymCrypt

sudo ninja -C /usr/local/src/SymCrypt-OpenSSL/build
sudo ninja -C /usr/local/src/SymCrypt-OpenSSL/build install
sudo ldconfig
```

Verify the provider module:

```bash
ls /usr/local/lib/ossl-modules/symcryptprovider.so
# Must exist
```

### B.4 Create the SymCrypt OpenSSL provider configuration

Create `/opt/pq-ca/openssl-symcrypt.cnf`:

```bash
sudo tee /opt/pq-ca/openssl-symcrypt.cnf > /dev/null << 'EOF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default  = default_sect
symcrypt = symcrypt_sect

[default_sect]
activate = 1

[symcrypt_sect]
module   = /usr/local/lib/ossl-modules/symcryptprovider.so
activate = 1
EOF
```

### B.5 Verify ML-DSA and ML-KEM are available

```bash
OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf \
  openssl list -signature-algorithms | grep -i ml-dsa

OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf \
  openssl list -kem-algorithms | grep -i ml-kem
```


---

## Part 3 — Build the CA Hierarchy (CA VM)

This part is **identical for both Option A and Option B**. The only difference is which
`OPENSSL_CONF` is active in your environment. Confirm before proceeding:

```bash
echo $OPENSSL_CONF
# Must print either /opt/pq-ca/openssl-pq.cnf or /opt/pq-ca/openssl-symcrypt.cnf
```

### 3.1 Write the Root CA configuration file

Create `/opt/pq-ca/root-ca.cnf`:

```bash
sudo tee /opt/pq-ca/root-ca.cnf > /dev/null << 'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /opt/pq-ca/root-ca
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
RANDFILE          = $dir/private/.rand
private_key       = $dir/private/root-ca.key.pem
certificate       = $dir/certs/root-ca.cert.pem
crlnumber         = $dir/crlnumber
crl               = $dir/crl/root-ca.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
policy            = policy_strict

[ policy_strict ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 3072
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_root_ca

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

[ v3_root_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
basicConstraints        = critical, CA:true
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
basicConstraints        = critical, CA:true, pathlen:0
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

[ crl_ext ]
authorityKeyIdentifier  = keyid:always
EOF
```

### 3.2 Write the Intermediate CA configuration file

Create `/opt/pq-ca/intermediate-ca.cnf`:

```bash
sudo tee /opt/pq-ca/intermediate-ca.cnf > /dev/null << 'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /opt/pq-ca/intermediate-ca
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
RANDFILE          = $dir/private/.rand
private_key       = $dir/private/intermediate-ca.key.pem
certificate       = $dir/certs/intermediate-ca.cert.pem
crlnumber         = $dir/crlnumber
crl               = $dir/crl/intermediate-ca.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 825
preserve          = no
policy            = policy_loose

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name

[ server_cert ]
basicConstraints        = CA:FALSE
nsComment               = "PQ Server Certificate"
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer:always
keyUsage                = critical, digitalSignature
extendedKeyUsage        = serverAuth
subjectAltName          = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1  = 127.0.0.1

[ crl_ext ]
authorityKeyIdentifier  = keyid:always
EOF
```

> The `[ alt_names ]` block above is a placeholder. It is overridden per-certificate in Part 4
> when issuing the server certificate.

### 3.3 Generate the Root CA private key (ML-DSA-87)

```bash
sudo openssl genpkey \
  -algorithm ml-dsa-87 \
  -out /opt/pq-ca/root-ca/private/root-ca.key.pem

sudo chmod 400 /opt/pq-ca/root-ca/private/root-ca.key.pem
```

ML-DSA-87 is NIST Security Level 5 (~AES-256). This key is the most sensitive asset in the lab.
In production you would generate it on an air-gapped HSM.

### 3.4 Self-sign the Root CA certificate (20-year validity)

```bash
sudo openssl req \
  -config /opt/pq-ca/root-ca.cnf \
  -key /opt/pq-ca/root-ca/private/root-ca.key.pem \
  -new -x509 -days 7300 \
  -extensions v3_root_ca \
  -out /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  -subj "/C=US/ST=Washington/O=TestOrg/CN=TestOrg PQ Root CA"

sudo chmod 444 /opt/pq-ca/root-ca/certs/root-ca.cert.pem
```

Verify:

```bash
openssl x509 -in /opt/pq-ca/root-ca/certs/root-ca.cert.pem -noout -text \
  | grep -E "Subject:|Public Key Algorithm:|Not After"
# Expected: Subject contains "TestOrg PQ Root CA"
# Expected: Public Key Algorithm: id-ml-dsa-87 (or id-MLDSA87)
```

### 3.5 Generate the Intermediate CA private key (ML-DSA-65)

```bash
sudo openssl genpkey \
  -algorithm ml-dsa-65 \
  -out /opt/pq-ca/intermediate-ca/private/intermediate-ca.key.pem

sudo chmod 400 /opt/pq-ca/intermediate-ca/private/intermediate-ca.key.pem
```

### 3.6 Create the Intermediate CA CSR

```bash
sudo openssl req \
  -config /opt/pq-ca/root-ca.cnf \
  -key /opt/pq-ca/intermediate-ca/private/intermediate-ca.key.pem \
  -new -sha256 \
  -out /opt/pq-ca/intermediate-ca/csr/intermediate-ca.csr.pem \
  -subj "/C=US/ST=Washington/O=TestOrg/CN=TestOrg PQ Intermediate CA"
```

### 3.7 Sign the Intermediate CA with the Root CA (10-year validity)

```bash
sudo openssl ca \
  -config /opt/pq-ca/root-ca.cnf \
  -extensions v3_intermediate_ca \
  -days 3650 -notext -md sha256 -batch \
  -in /opt/pq-ca/intermediate-ca/csr/intermediate-ca.csr.pem \
  -out /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem

sudo chmod 444 /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem
```

### 3.8 Build the CA chain bundle

The chain bundle concatenates the Intermediate CA cert followed by the Root CA cert:

```bash
sudo bash -c 'cat \
  /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem \
  /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  > /opt/pq-ca/intermediate-ca/certs/ca-chain.cert.pem'

sudo chmod 444 /opt/pq-ca/intermediate-ca/certs/ca-chain.cert.pem
```

### 3.9 Verify the chain

```bash
openssl verify \
  -CAfile /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem
# Expected: intermediate-ca.cert.pem: OK
```

**Expected directory structure on the CA VM at this point:**

```
/opt/pq-ca/
├── openssl-pq.cnf          (Option A) OR openssl-symcrypt.cnf (Option B)
├── root-ca.cnf
├── intermediate-ca.cnf
├── root-ca/
│   ├── certs/root-ca.cert.pem         ← Root CA cert (distribute freely)
│   ├── private/root-ca.key.pem        ← Root CA key (protect carefully!)
│   ├── index.txt                      ← CA database (one entry: intermediate cert)
│   ├── serial                         ← Next serial (1001)
│   ├── crlnumber
│   └── newcerts/1000.pem              ← Copy of intermediate cert
└── intermediate-ca/
    ├── certs/
    │   ├── intermediate-ca.cert.pem
    │   └── ca-chain.cert.pem          ← Chain bundle
    ├── private/intermediate-ca.key.pem
    ├── csr/intermediate-ca.csr.pem
    ├── index.txt
    ├── serial
    └── crlnumber
```


---

## Part 4 — Issue a Server Certificate and Configure Apache (CA VM → Web VM)

### 4.1 Install build dependencies on the Web VM

SSH into the **Web VM** and run:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  build-essential cmake ninja-build git curl wget \
  libssl-dev python3 python3-pip pkg-config gcc g++ ca-certificates \
  apache2 libapache2-mod-ssl jq
```

Then install the PQ provider on the Web VM using the same steps as Part 1 (LibOQS) or Part 2
(SymCrypt).

> **Shortcut:** Instead of rebuilding from source, copy the provider binary from the CA VM:
>
> ```bash
> # Run on the CA VM — copy .so and config to the Web VM
>
> # Option A (LibOQS):
> scp -i ~/.ssh/id_rsa \
>   /usr/local/lib/ossl-modules/oqsprovider.so \
>   /opt/pq-ca/openssl-pq.cnf \
>   azureuser@<WEB_IP>:/tmp/
>
> # On the Web VM:
> sudo install -m 755 /tmp/oqsprovider.so /usr/local/lib/ossl-modules/oqsprovider.so
> sudo install -m 644 /tmp/openssl-pq.cnf /etc/ssl/openssl-pq.cnf
> sudo ldconfig
>
> # Option B (SymCrypt):
> # scp -i ~/.ssh/id_rsa \
> #   /usr/local/lib/ossl-modules/symcryptprovider.so \
> #   /opt/pq-ca/openssl-symcrypt.cnf \
> #   azureuser@<WEB_IP>:/tmp/
> # On the Web VM:
> # sudo install -m 755 /tmp/symcryptprovider.so /usr/local/lib/ossl-modules/symcryptprovider.so
> # sudo install -m 644 /tmp/openssl-symcrypt.cnf /etc/ssl/openssl-symcrypt.cnf
> # sudo ldconfig
> ```

The automated scripts (`04-issue-server-cert.sh`) use this shortcut automatically.

### 4.2 Generate the server private key (ML-DSA-65, on CA VM)

Set your domain/IP variable. Use the actual public IP or hostname clients will connect to:

```bash
export DOMAIN=<WEB_VM_IP_OR_HOSTNAME>   # e.g. 10.0.1.4 or pq-web.example.com
```

```bash
sudo openssl genpkey \
  -algorithm ml-dsa-65 \
  -out /opt/pq-ca/intermediate-ca/private/${DOMAIN}.key.pem

sudo chmod 400 /opt/pq-ca/intermediate-ca/private/${DOMAIN}.key.pem
```

### 4.3 Create a per-certificate intermediate CA config with correct SANs

The certificate Subject Alternative Name (SAN) must match what clients use to connect. Create a
copy of the intermediate CA config with the correct entries:

**For an IP address target:**

```bash
sudo cp /opt/pq-ca/intermediate-ca.cnf \
        /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf

# Replace the alt_names section with the correct IP
sudo sed -i '/^\[ alt_names \]/,/^\[/{/^\[ alt_names \]/!{/^\[/!d}}' \
  /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf

sudo tee -a /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf > /dev/null << EOF

[ alt_names ]
IP.1  = ${DOMAIN}
IP.2  = 127.0.0.1
EOF
```

**For a hostname target:**

```bash
sudo cp /opt/pq-ca/intermediate-ca.cnf \
        /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf

sudo sed -i '/^\[ alt_names \]/,/^\[/{/^\[ alt_names \]/!{/^\[/!d}}' \
  /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf

sudo tee -a /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf > /dev/null << EOF

[ alt_names ]
DNS.1 = ${DOMAIN}
DNS.2 = www.${DOMAIN}
IP.1  = 127.0.0.1
EOF
```

### 4.4 Create the server CSR

```bash
sudo openssl req \
  -config /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf \
  -key /opt/pq-ca/intermediate-ca/private/${DOMAIN}.key.pem \
  -new -sha256 \
  -out /opt/pq-ca/intermediate-ca/csr/${DOMAIN}.csr.pem \
  -subj "/C=US/ST=Washington/O=TestOrg/CN=${DOMAIN}"
```

### 4.5 Sign the server certificate with the Intermediate CA (825-day validity)

```bash
sudo openssl ca \
  -config /opt/pq-ca/intermediate-ca-${DOMAIN}.cnf \
  -extensions server_cert \
  -days 825 -notext -md sha256 -batch \
  -in /opt/pq-ca/intermediate-ca/csr/${DOMAIN}.csr.pem \
  -out /opt/pq-ca/intermediate-ca/certs/${DOMAIN}.cert.pem

sudo chmod 444 /opt/pq-ca/intermediate-ca/certs/${DOMAIN}.cert.pem
```

Verify the server certificate chain:

```bash
openssl verify \
  -CAfile /opt/pq-ca/intermediate-ca/certs/ca-chain.cert.pem \
  /opt/pq-ca/intermediate-ca/certs/${DOMAIN}.cert.pem
# Expected: OK

openssl x509 -in /opt/pq-ca/intermediate-ca/certs/${DOMAIN}.cert.pem \
  -noout -text | grep -A5 "Subject Alternative Name"
# Must show the IP or hostname you configured
```

### 4.6 Copy certificates and provider to the Web VM (from CA VM)

```bash
export WEB_IP=<WEB_VM_IP>
export WEB_USER=azureuser    # or ubuntu, or your actual user
export SSH_KEY=~/.ssh/id_rsa

SSH_OPTS="-o StrictHostKeyChecking=no -i ${SSH_KEY}"

# Server cert and private key
scp ${SSH_OPTS} \
  /opt/pq-ca/intermediate-ca/certs/${DOMAIN}.cert.pem \
  ${WEB_USER}@${WEB_IP}:/tmp/

scp ${SSH_OPTS} \
  /opt/pq-ca/intermediate-ca/private/${DOMAIN}.key.pem \
  ${WEB_USER}@${WEB_IP}:/tmp/

# CA chain bundle
scp ${SSH_OPTS} \
  /opt/pq-ca/intermediate-ca/certs/ca-chain.cert.pem \
  ${WEB_USER}@${WEB_IP}:/tmp/pq-ca-chain.cert.pem

# Option A — LibOQS provider and config
scp ${SSH_OPTS} \
  /usr/local/lib/ossl-modules/oqsprovider.so \
  /opt/pq-ca/openssl-pq.cnf \
  ${WEB_USER}@${WEB_IP}:/tmp/

# Option B — SymCrypt provider and config
# scp ${SSH_OPTS} \
#   /usr/local/lib/ossl-modules/symcryptprovider.so \
#   /opt/pq-ca/openssl-symcrypt.cnf \
#   ${WEB_USER}@${WEB_IP}:/tmp/
```

### 4.7 Install certificates and provider on the Web VM

SSH into the **Web VM** and run:

```bash
# Certs
sudo install -m 644 /tmp/${DOMAIN}.cert.pem   /etc/ssl/certs/${DOMAIN}.cert.pem
sudo install -m 600 /tmp/${DOMAIN}.key.pem    /etc/ssl/private/${DOMAIN}.key.pem
sudo install -m 644 /tmp/pq-ca-chain.cert.pem /etc/ssl/certs/pq-ca-chain.cert.pem

# Option A — LibOQS
sudo mkdir -p /usr/local/lib/ossl-modules
sudo install -m 755 /tmp/oqsprovider.so /usr/local/lib/ossl-modules/oqsprovider.so
sudo install -m 644 /tmp/openssl-pq.cnf /etc/ssl/openssl-pq.cnf
sudo ldconfig

# Option B — SymCrypt (uncomment if using):
# sudo install -m 755 /tmp/symcryptprovider.so /usr/local/lib/ossl-modules/symcryptprovider.so
# sudo install -m 644 /tmp/openssl-symcrypt.cnf /etc/ssl/openssl-symcrypt.cnf
# sudo ldconfig
```

### 4.8 Inject OPENSSL_CONF into Apache's environment

Apache must load the PQ provider when it starts. Add the environment variable to Apache's env
drop-in directory:

```bash
# On the Web VM

# Option A:
sudo mkdir -p /etc/apache2/envvars.d
echo 'export OPENSSL_CONF=/etc/ssl/openssl-pq.cnf' \
  | sudo tee /etc/apache2/envvars.d/pq-openssl.conf

# Option B:
# echo 'export OPENSSL_CONF=/etc/ssl/openssl-symcrypt.cnf' \
#   | sudo tee /etc/apache2/envvars.d/pq-openssl.conf
```

### 4.9 Create the Apache TLS virtual host configuration

On the **Web VM**, create `/etc/apache2/sites-available/pq-ssl.conf`:

```bash
export DOMAIN=<WEB_VM_IP_OR_HOSTNAME>   # same value used in step 4.2

sudo tee /etc/apache2/sites-available/pq-ssl.conf > /dev/null << EOF
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile      /etc/ssl/certs/${DOMAIN}.cert.pem
    SSLCertificateKeyFile   /etc/ssl/private/${DOMAIN}.key.pem
    SSLCertificateChainFile /etc/ssl/certs/pq-ca-chain.cert.pem

    # TLS 1.3 required — ML-KEM key exchange only works in TLS 1.3
    SSLProtocol -all +TLSv1.3

    # Post-quantum key exchange groups
    # x25519_mlkem768 = hybrid (X25519 + ML-KEM-768) — widest compatibility
    # mlkem768        = pure post-quantum ML-KEM-768
    # mlkem1024       = pure post-quantum ML-KEM-1024
    SSLOpenSSLConfCmd Groups "x25519_mlkem768:mlkem768:mlkem1024:x25519:P-256"
    SSLOpenSSLConfCmd ECDHParameters "x25519_mlkem768"

    SSLCipherSuite TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256

    SSLUseStapling on
    SSLStaplingCache shmcb:/var/run/apache2/stapling(32768)

    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

    ErrorLog  \${APACHE_LOG_DIR}/pq-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/pq-ssl-access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName ${DOMAIN}
    Redirect permanent / https://${DOMAIN}/
</VirtualHost>
EOF
```

### 4.10 Enable the site and restart Apache

```bash
# On the Web VM
sudo a2enmod ssl headers
sudo a2ensite pq-ssl.conf
sudo apache2ctl configtest          # Must print: Syntax OK
sudo systemctl restart apache2
sudo systemctl is-active apache2    # Must print: active
```

If `configtest` fails, the most common causes are:
- The cert or key file paths do not exist — check step 4.7
- `OPENSSL_CONF` path in step 4.8 does not match where you placed the `.cnf` file
- The `SSLCertificateFile` path domain portion does not match what you set for `$DOMAIN`

---

## Part 5 — Prepare the Client VM

### 5.1 Install the PQ provider on the Client VM

Repeat Part 1 (LibOQS) or Part 2 (SymCrypt) on the **Client VM**, or copy the provider `.so`
from the CA VM using the same shortcut as step 4.1.

For Option A, place the config at `/opt/pq-ca/openssl-pq.cnf` on the Client VM.
For Option B, place it at `/opt/pq-ca/openssl-symcrypt.cnf`.

### 5.2 Copy and trust the Root CA certificate (Client VM)

From the **CA VM**:

```bash
scp -i ${SSH_KEY} \
  /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  ${CLIENT_USER}@${CLIENT_IP}:/tmp/pq-root-ca.crt
```

On the **Client VM**:

```bash
sudo install -m 644 /tmp/pq-root-ca.crt \
  /usr/local/share/ca-certificates/pq-root-ca.crt
sudo update-ca-certificates
# Expected output: 1 added, 0 removed; done.
```

---

## Part 6 — Verification

### 6.1 Quick TLS test (from Client VM or CA VM)

```bash
# Option A
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl s_client \
    -connect <WEB_IP>:443 \
    -CAfile /usr/local/share/ca-certificates/pq-root-ca.crt \
    -groups x25519_mlkem768 \
    -tls1_3 \
    -showcerts \
    </dev/null 2>&1 | grep -E "Protocol|Server Temp Key|Public Key Algorithm|Verify"
```

**Expected output:**

```
Protocol  : TLSv1.3
Server Temp Key: X25519_MLKEM768, ...
Public Key Algorithm: id-ml-dsa-65
Verify return code: 0 (ok)
```

### 6.2 Run the full verification suite (05-verify-tls.sh)

Copy `05-verify-tls.sh` from the scripts folder to the testing machine, then:

```bash
bash 05-verify-tls.sh \
  --target <WEB_IP_OR_HOST> \
  --ca-cert /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  --provider liboqs    # or: symcrypt
```

All 8 tests should pass:

| # | Test | Expected result |
|---|------|----------------|
| 1 | TCP connectivity on port 443 | PASS |
| 2 | TLS handshake with chain verification | PASS |
| 3 | Server certificate uses ML-DSA | PASS |
| 4 | TLS 1.3 negotiated | PASS |
| 5 | PQ/hybrid key exchange (`x25519_mlkem768`) | PASS |
| 6 | Chain validates to Root CA | PASS |
| 7 | HTTP (port 80) redirects to HTTPS | PASS |
| 8 | HSTS header present | PASS |

### 6.3 Run the client-side verification suite (06-client-verify.sh)

Copy `06-client-verify.sh` to the **Client VM**, then:

```bash
bash 06-client-verify.sh \
  --target <WEB_IP_OR_HOST> \
  --provider liboqs \
  --ca-cert /usr/local/share/ca-certificates/pq-root-ca.crt
```

All 4 tests should pass:

| # | Test | Expected result |
|---|------|----------------|
| 1 | TLS 1.3 handshake from client | PASS |
| 2 | Certificate chain validates to trusted Root CA | PASS |
| 3 | PQ/hybrid key exchange negotiated | PASS |
| 4 | TLS 1.2 rejected by server | PASS |


---

## End-State Comparison Checklist

Use this to compare a manual build against a scripted deployment. Run these commands on each VM.

### CA VM checklist

```bash
# OS
lsb_release -a | grep "Release:"
# Expected: 26.04

# OpenSSL
openssl version
# Expected: OpenSSL 3.x.x

# Option A: liboqs shared library
ls /usr/local/lib/liboqs.so*

# Option A: OQS provider module
ls /usr/local/lib/ossl-modules/oqsprovider.so

# Option B: SymCrypt shared library
ls -la /usr/local/lib/libsymcrypt.so

# Option B: SymCrypt provider module
ls /usr/local/lib/ossl-modules/symcryptprovider.so

# Provider config (A)
cat /opt/pq-ca/openssl-pq.cnf

# Provider config (B)
cat /opt/pq-ca/openssl-symcrypt.cnf

# ML-DSA available (replace with correct OPENSSL_CONF)
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf openssl list -signature-algorithms | grep ml-dsa

# ML-KEM available
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf openssl list -kem-algorithms | grep ml-kem

# Root CA key (mode must be 400)
stat /opt/pq-ca/root-ca/private/root-ca.key.pem | grep "Access:"

# Root CA cert (mode must be 444)
stat /opt/pq-ca/root-ca/certs/root-ca.cert.pem | grep "Access:"

# Root CA algorithm
openssl x509 -in /opt/pq-ca/root-ca/certs/root-ca.cert.pem -noout -text \
  | grep "Public Key Algorithm"
# Expected: id-ml-dsa-87 (or id-MLDSA87)

# Intermediate CA algorithm
openssl x509 -in /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem -noout -text \
  | grep "Public Key Algorithm"
# Expected: id-ml-dsa-65 (or id-MLDSA65)

# Chain verification
openssl verify \
  -CAfile /opt/pq-ca/root-ca/certs/root-ca.cert.pem \
  /opt/pq-ca/intermediate-ca/certs/intermediate-ca.cert.pem
# Expected: OK

# CA database has at least one entry (the intermediate cert)
cat /opt/pq-ca/root-ca/index.txt | wc -l
# Expected: 1 or more

# Serial counter advanced
cat /opt/pq-ca/root-ca/serial
# Expected: 1001 (after one certificate issued)

# Provider env sourced in profile
cat /opt/pq-ca-setup/env.sh
```

### Web VM checklist

```bash
# Apache running
systemctl is-active apache2
# Expected: active

# Option A: Provider module
ls /usr/local/lib/ossl-modules/oqsprovider.so

# Option B: Provider module
ls /usr/local/lib/ossl-modules/symcryptprovider.so

# Provider config for Apache
cat /etc/ssl/openssl-pq.cnf          # (Option A)
# cat /etc/ssl/openssl-symcrypt.cnf  # (Option B)

# Apache OPENSSL_CONF injection
cat /etc/apache2/envvars.d/pq-openssl.conf
# Expected: export OPENSSL_CONF=/etc/ssl/openssl-pq.cnf

# Server cert (mode 644)
stat /etc/ssl/certs/<DOMAIN>.cert.pem | grep "Access:"

# Server key (mode 600)
stat /etc/ssl/private/<DOMAIN>.key.pem | grep "Access:"

# CA chain
stat /etc/ssl/certs/pq-ca-chain.cert.pem

# VHost enabled
sudo a2query -s pq-ssl
# Expected: pq-ssl (enabled by ...)

# TLS protocol setting
grep SSLProtocol /etc/apache2/sites-available/pq-ssl.conf
# Expected: SSLProtocol -all +TLSv1.3

# PQ key exchange groups
grep Groups /etc/apache2/sites-available/pq-ssl.conf
# Expected: x25519_mlkem768:mlkem768:...

# HSTS header
curl -sk -I https://<WEB_IP>/ | grep -i Strict
# Expected: Strict-Transport-Security: max-age=...

# Cert algorithm on wire
OPENSSL_CONF=/etc/ssl/openssl-pq.cnf \
  openssl s_client -connect <WEB_IP>:443 -tls1_3 </dev/null 2>&1 \
  | openssl x509 -noout -text 2>/dev/null | grep "Public Key Algorithm"
# Expected: id-ml-dsa-65
```

### Client VM checklist

```bash
# Root CA trusted
ls /usr/local/share/ca-certificates/pq-root-ca.crt

# TLS 1.3 handshake
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl s_client -connect <WEB_IP>:443 -tls1_3 \
  -CAfile /usr/local/share/ca-certificates/pq-root-ca.crt \
  </dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)

# PQ key exchange
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl s_client -connect <WEB_IP>:443 -tls1_3 \
  -groups x25519_mlkem768 \
  -CAfile /usr/local/share/ca-certificates/pq-root-ca.crt \
  </dev/null 2>&1 | grep "Server Temp Key"
# Expected: Server Temp Key: X25519_MLKEM768, ...

# TLS 1.2 rejected
OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
  openssl s_client -connect <WEB_IP>:443 -tls1_2 \
  </dev/null 2>&1 | grep -i "handshake failure\|protocol version\|alert"
# Expected: handshake failure or unsupported protocol
```

---

## Common Errors and Fixes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `ml-dsa` not listed in algorithms | Provider `.so` not found or wrong path in `.cnf` | Verify `.so` exists at the `module=` path; run `sudo ldconfig` |
| `Cannot open shared object: libsymcrypt.so` | `ldconfig` not run after SymCrypt install | `sudo ldconfig` |
| `Server Temp Key: X25519` only — no MLKEM | Apache does not have PQ provider loaded | Check `/etc/apache2/envvars.d/pq-openssl.conf` exists and path matches |
| `Verify return code: 21` (cert not trusted) | Root CA not in client trust store | `sudo update-ca-certificates` on the client |
| Apache `configtest` fails with SSL cert error | Cert SAN does not match `ServerName` | Reissue cert with correct IP/hostname in `alt_names` |
| `SSLProtocol` directive error in Apache | `mod_ssl` not enabled | `sudo a2enmod ssl` then restart Apache |
| TLS 1.2 accepted (should be rejected) | `SSLProtocol` directive missing from vhost | Add `-all +TLSv1.3` to `pq-ssl.conf` |
| SymCrypt build fails — killed by OOM | Less than 16 GB RAM on build VM | Use a larger VM; SymCrypt peaks ~8 GB compile RAM |
| `oqsprovider.so` not installed after `ninja install` | cmake prefix mismatch | Check `-DCMAKE_INSTALL_PREFIX=/usr/local` is set; look in `/usr/local/lib/ossl-modules/` |
| `CA_default: No private key` when signing | Wrong `OPENSSL_CONF` or wrong cnf path | Confirm `$OPENSSL_CONF` and `-config` both point to the right file |
| Intermediate cert signed by wrong Root | Ran `openssl ca` with wrong `-config` | Delete the bad cert, reset serial if needed, reissue with correct config |

---

## Key Differences Between Manual and Scripted Deployments

| Aspect | Manual | Scripted (`00-remote-deploy.sh`) |
|--------|--------|----------------------------------|
| Provider installation location | You build on each VM or copy manually | CA builds once; `.so` copied to Web/Client via SCP |
| SSH key for CA→Web transfers | You run SCP commands explicitly | Script stages `--ssh-key` into `/tmp/pq-web-ssh-key` and uses it automatically |
| Apache OPENSSL_CONF | You create `/etc/apache2/envvars.d/pq-openssl.conf` | Script writes this via remote SSH heredoc |
| VM environment variables | You source `env.sh` or set manually | Cloud-init writes `/etc/profile.d/pq-provider.sh` and `/opt/pq-ca-setup/env.sh` |
| CA directory init | You run `mkdir -p ...` commands | Cloud-init runs these on first boot; `03-build-ca.sh` also re-runs them idempotently |
| SAN configuration | You create per-cert `.cnf` file manually | Script uses `sed` to strip and rewrite `[ alt_names ]` section |
| Verification | You run `05-verify-tls.sh` and `06-client-verify.sh` manually | `00-remote-deploy.sh` runs them automatically after deployment |
