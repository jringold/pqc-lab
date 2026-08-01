#!/usr/bin/env bash
# =============================================================================
# 03-build-ca.sh — Build Root CA and Intermediate CA hierarchy
#
# Creates:
#   - CA config files (root-ca.cnf, intermediate-ca.cnf)
#   - Root CA key (ML-DSA-87) and self-signed cert
#   - Intermediate CA key (ML-DSA-65), CSR, and cert signed by Root CA
#   - CA chain bundle: intermediate.pem + root.pem
#
# Run on the CA VM after 02-install-provider.sh completes:
#   sudo bash /tmp/03-build-ca.sh
#
# Environment:
#   PQ_PROVIDER   = liboqs | symcrypt  (default: from /opt/pq-ca-setup/env.sh)
#   ORG_NAME      = organization name in cert subjects  (default: TestOrg)
#   ORG_COUNTRY   = 2-letter code                       (default: US)
#   ORG_STATE     = state/province                      (default: Washington)
# =============================================================================
set -euo pipefail

# Source env written by cloud-init / 01-azure-infra.sh
[[ -f /opt/pq-ca-setup/env.sh ]] && source /opt/pq-ca-setup/env.sh

PROVIDER="${PQ_PROVIDER:-liboqs}"
ORG_NAME="${ORG_NAME:-TestOrg}"
ORG_COUNTRY="${ORG_COUNTRY:-US}"
ORG_STATE="${ORG_STATE:-Washington}"
CA_ROOT=/opt/pq-ca
LOG=/var/log/pq-setup.log

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root (sudo bash $0)"

# Select OpenSSL config based on provider
if [[ "$PROVIDER" == "liboqs" ]]; then
  OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf
  ROOT_CNF="${CA_ROOT}/root-ca.cnf"
  INT_CNF="${CA_ROOT}/intermediate-ca.cnf"
else
  OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf
  ROOT_CNF="${CA_ROOT}/root-ca-symcrypt.cnf"
  INT_CNF="${CA_ROOT}/intermediate-ca-symcrypt.cnf"
fi
export OPENSSL_CONF

info "=== Building CA hierarchy (${PROVIDER}) ==="
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] START build-ca provider=${PROVIDER}" >> "$LOG"

# =============================================================================
# Write CA config files
# =============================================================================
info "Writing Root CA config: ${ROOT_CNF}"
cat > "${ROOT_CNF}" << CONF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${CA_ROOT}/root-ca
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/root-ca.key.pem
certificate       = \$dir/certs/root-ca.cert.pem
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/root-ca.crl.pem
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
CONF

info "Writing Intermediate CA config: ${INT_CNF}"
cat > "${INT_CNF}" << CONF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${CA_ROOT}/intermediate-ca
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/intermediate-ca.key.pem
certificate       = \$dir/certs/intermediate-ca.cert.pem
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/intermediate-ca.crl.pem
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
# Populated per-certificate by 04-issue-server-cert.sh
DNS.1 = localhost
IP.1  = 127.0.0.1

[ crl_ext ]
authorityKeyIdentifier  = keyid:always
CONF

# For SymCrypt, also create copies aligned to standard paths
if [[ "$PROVIDER" == "symcrypt" ]]; then
  cp "${ROOT_CNF}" "${CA_ROOT}/root-ca.cnf" 2>/dev/null || true
  cp "${INT_CNF}"  "${CA_ROOT}/intermediate-ca.cnf" 2>/dev/null || true
fi

success "CA config files written"

# =============================================================================
# Root CA key and certificate (ML-DSA-87)
# =============================================================================
ROOT_KEY="${CA_ROOT}/root-ca/private/root-ca.key.pem"
ROOT_CERT="${CA_ROOT}/root-ca/certs/root-ca.cert.pem"

if [[ -f "$ROOT_CERT" ]]; then
  warn "Root CA cert already exists — skipping key generation"
  warn "Delete ${ROOT_CERT} to regenerate"
else
  info "Generating Root CA private key (ML-DSA-87)..."
  openssl genpkey \
    -algorithm ml-dsa-87 \
    -out "${ROOT_KEY}"
  chmod 400 "${ROOT_KEY}"
  success "Root CA key generated"

  info "Self-signing Root CA certificate (20-year validity)..."
  openssl req \
    -config "${ROOT_CNF}" \
    -key "${ROOT_KEY}" \
    -new -x509 -days 7300 \
    -extensions v3_root_ca \
    -out "${ROOT_CERT}" \
    -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/O=${ORG_NAME}/CN=${ORG_NAME} PQ Root CA"
  chmod 444 "${ROOT_CERT}"
  success "Root CA certificate created"
fi

# Verify Root CA cert
openssl x509 -in "${ROOT_CERT}" -noout -text \
  | grep -E "Subject:|Issuer:|Public Key Algorithm|Not After" \
  | tee -a "$LOG"

# =============================================================================
# Intermediate CA key, CSR, and certificate (ML-DSA-65)
# =============================================================================
INT_KEY="${CA_ROOT}/intermediate-ca/private/intermediate-ca.key.pem"
INT_CSR="${CA_ROOT}/intermediate-ca/csr/intermediate-ca.csr.pem"
INT_CERT="${CA_ROOT}/intermediate-ca/certs/intermediate-ca.cert.pem"
CHAIN="${CA_ROOT}/intermediate-ca/certs/ca-chain.cert.pem"

if [[ -f "$INT_CERT" ]]; then
  warn "Intermediate CA cert already exists — skipping"
else
  info "Generating Intermediate CA private key (ML-DSA-65)..."
  openssl genpkey \
    -algorithm ml-dsa-65 \
    -out "${INT_KEY}"
  chmod 400 "${INT_KEY}"
  success "Intermediate CA key generated"

  info "Creating Intermediate CA CSR..."
  openssl req \
    -config "${ROOT_CNF}" \
    -key "${INT_KEY}" \
    -new -sha256 \
    -out "${INT_CSR}" \
    -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/O=${ORG_NAME}/CN=${ORG_NAME} PQ Intermediate CA"
  success "Intermediate CA CSR created"

  info "Signing Intermediate CA with Root CA (10-year validity)..."
  openssl ca \
    -config "${ROOT_CNF}" \
    -extensions v3_intermediate_ca \
    -days 3650 -notext -md sha256 -batch \
    -in "${INT_CSR}" \
    -out "${INT_CERT}"
  chmod 444 "${INT_CERT}"
  success "Intermediate CA certificate signed"
fi

# Build chain file
info "Building CA chain bundle..."
cat "${INT_CERT}" "${ROOT_CERT}" > "${CHAIN}"
chmod 444 "${CHAIN}"
success "CA chain written to: ${CHAIN}"

# Verify chain
info "Verifying certificate chain..."
openssl verify -CAfile "${ROOT_CERT}" "${INT_CERT}" \
  | tee -a "$LOG" \
  || error "Chain verification FAILED"
success "Chain verification passed"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DONE build-ca" >> "$LOG"
echo "CA_BUILT=1" >> /opt/pq-ca-setup/.cloud-init-status

echo
echo "============================================================"
echo "  CA HIERARCHY COMPLETE"
echo "============================================================"
echo "  Root CA cert      : ${ROOT_CERT}"
echo "  Intermediate cert : ${INT_CERT}"
echo "  Chain bundle      : ${CHAIN}"
echo "  Provider          : ${PROVIDER}"
echo
echo "  ⚠️  In production: export the Root CA key to offline storage"
echo "     and remove it from this VM before issuing any certs."
echo "============================================================"
