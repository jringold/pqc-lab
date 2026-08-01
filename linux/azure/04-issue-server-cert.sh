#!/usr/bin/env bash
# =============================================================================
# 04-issue-server-cert.sh — Issue ML-DSA server cert and deploy to Apache
#
# Run on the CA VM after 03-build-ca.sh.
# Generates a server cert, copies it and the PQ provider config to the
# web VM via SCP, then writes the Apache vhost config.
#
# Usage (on CA VM):
#   sudo bash /tmp/04-issue-server-cert.sh \
#     --domain <DOMAIN_OR_IP> \
#     --web-ip  <WEB_VM_IP> \
#     --web-user azureuser
#
# If --domain is an IP address, the cert SAN will include the IP.
# If --domain is a hostname, SAN will include the hostname.
# =============================================================================
set -euo pipefail

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

[[ $EUID -eq 0 ]] || error "Run as root"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DOMAIN=""
WEB_IP=""
WEB_USER="azureuser"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)   DOMAIN="$2";   shift 2 ;;
    --web-ip)   WEB_IP="$2";   shift 2 ;;
    --web-user) WEB_USER="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2";  shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -n "$DOMAIN" ]] || error "--domain is required (hostname or IP of the web VM)"
[[ -n "$WEB_IP"  ]] || error "--web-ip is required (public IP of the web VM)"

# Detect if domain is an IP address
IS_IP=false
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_IP=true
fi

# Select OpenSSL config
if [[ "$PROVIDER" == "liboqs" ]]; then
  OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf
  INT_CNF="${CA_ROOT}/intermediate-ca.cnf"
else
  OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf
  INT_CNF="${CA_ROOT}/intermediate-ca-symcrypt.cnf"
fi
export OPENSSL_CONF

info "=== Issuing server certificate for: ${DOMAIN} ==="
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] START issue-cert domain=${DOMAIN}" >> "$LOG"

# ---------------------------------------------------------------------------
# Write a per-cert intermediate CA config with correct SANs
# ---------------------------------------------------------------------------
CERT_INT_CNF="${CA_ROOT}/intermediate-ca-${DOMAIN}.cnf"

# Build the alt_names section
if $IS_IP; then
  ALT_SECTION="IP.1  = ${DOMAIN}
IP.2  = 127.0.0.1"
else
  ALT_SECTION="DNS.1 = ${DOMAIN}
DNS.2 = www.${DOMAIN}
IP.1  = 127.0.0.1"
fi

cat "${INT_CNF}" | \
  sed "/^\[ alt_names \]/,/^\[/{/^\[ alt_names \]/!{/^\[/!d}}" \
  > "${CERT_INT_CNF}"

# Append the correct alt_names block
cat >> "${CERT_INT_CNF}" << CONF

[ alt_names ]
${ALT_SECTION}
CONF

# ---------------------------------------------------------------------------
# Generate server key and certificate
# ---------------------------------------------------------------------------
SRV_KEY="${CA_ROOT}/intermediate-ca/private/${DOMAIN}.key.pem"
SRV_CSR="${CA_ROOT}/intermediate-ca/csr/${DOMAIN}.csr.pem"
SRV_CERT="${CA_ROOT}/intermediate-ca/certs/${DOMAIN}.cert.pem"

if [[ -f "$SRV_CERT" ]]; then
  warn "Server cert already exists for ${DOMAIN} — regenerating"
  rm -f "${SRV_KEY}" "${SRV_CSR}" "${SRV_CERT}"
fi

info "Generating server private key (ML-DSA-65)..."
openssl genpkey \
  -algorithm ml-dsa-65 \
  -out "${SRV_KEY}"
chmod 400 "${SRV_KEY}"
success "Server key generated"

info "Creating server CSR..."
openssl req \
  -config "${CERT_INT_CNF}" \
  -key "${SRV_KEY}" \
  -new -sha256 \
  -out "${SRV_CSR}" \
  -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/O=${ORG_NAME}/CN=${DOMAIN}"
success "Server CSR created"

info "Signing server certificate (825-day validity)..."
openssl ca \
  -config "${CERT_INT_CNF}" \
  -extensions server_cert \
  -days 825 -notext -md sha256 -batch \
  -in "${SRV_CSR}" \
  -out "${SRV_CERT}"
chmod 444 "${SRV_CERT}"
success "Server certificate signed"

# Verify cert chain
info "Verifying server certificate against CA chain..."
openssl verify \
  -CAfile "${CA_ROOT}/intermediate-ca/certs/ca-chain.cert.pem" \
  "${SRV_CERT}" \
  | tee -a "$LOG" \
  || error "Server cert chain verification FAILED"
success "Server cert verified"

# ---------------------------------------------------------------------------
# Determine provider conf file path for web VM
# ---------------------------------------------------------------------------
if [[ "$PROVIDER" == "liboqs" ]]; then
  PROVIDER_CONF=/opt/pq-ca/openssl-pq.cnf
  PROVIDER_DEST=/etc/ssl/openssl-pq.cnf
  APACHE_ENV_LINE="export OPENSSL_CONF=/etc/ssl/openssl-pq.cnf"
else
  PROVIDER_CONF=/opt/pq-ca/openssl-symcrypt.cnf
  PROVIDER_DEST=/etc/ssl/openssl-symcrypt.cnf
  APACHE_ENV_LINE="export OPENSSL_CONF=/etc/ssl/openssl-symcrypt.cnf"
fi

# ---------------------------------------------------------------------------
# Build Apache vhost config (written locally, then pushed)
# ---------------------------------------------------------------------------
VHOST_TMP="$(mktemp /tmp/pq-vhost-XXXX.conf)"
cat > "$VHOST_TMP" << VHOST
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile      /etc/ssl/certs/${DOMAIN}.cert.pem
    SSLCertificateKeyFile   /etc/ssl/private/${DOMAIN}.key.pem
    SSLCertificateChainFile /etc/ssl/certs/pq-ca-chain.cert.pem

    # TLS 1.3 required for ML-KEM key exchange
    SSLProtocol -all +TLSv1.3

    # Post-Quantum key exchange groups
    # x25519_mlkem768 = hybrid (X25519 + ML-KEM-768) — recommended for compatibility
    # mlkem768        = pure ML-KEM-768
    # mlkem1024       = pure ML-KEM-1024
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
VHOST

# ---------------------------------------------------------------------------
# Push everything to the web VM via SCP + SSH
# ---------------------------------------------------------------------------
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"
SCP_CMD="scp ${SSH_OPTS}"
SSH_CMD="ssh ${SSH_OPTS} ${WEB_USER}@${WEB_IP}"

info "Copying certificates and provider config to web VM (${WEB_IP})..."

# Copy certs
$SCP_CMD "${SRV_CERT}"  "${WEB_USER}@${WEB_IP}:/tmp/${DOMAIN}.cert.pem"
$SCP_CMD "${SRV_KEY}"   "${WEB_USER}@${WEB_IP}:/tmp/${DOMAIN}.key.pem"
$SCP_CMD "${CA_ROOT}/intermediate-ca/certs/ca-chain.cert.pem" \
         "${WEB_USER}@${WEB_IP}:/tmp/pq-ca-chain.cert.pem"

# Copy provider .so (and conf) so web VM can also do openssl s_client tests
if [[ "$PROVIDER" == "liboqs" ]]; then
  $SCP_CMD /usr/local/lib/ossl-modules/oqsprovider.so \
           "${WEB_USER}@${WEB_IP}:/tmp/oqsprovider.so"
else
  $SCP_CMD /usr/local/lib/ossl-modules/symcryptprovider.so \
           "${WEB_USER}@${WEB_IP}:/tmp/symcryptprovider.so"
fi
$SCP_CMD "${PROVIDER_CONF}" "${WEB_USER}@${WEB_IP}:/tmp/openssl-pq.cnf"

# Copy vhost config
$SCP_CMD "${VHOST_TMP}" "${WEB_USER}@${WEB_IP}:/tmp/pq-ssl.conf"

success "Files copied to web VM"

# Run remote setup on web VM
info "Configuring Apache on web VM..."
$SSH_CMD bash << REMOTE
set -euo pipefail

# Install certs
sudo install -m 644 /tmp/${DOMAIN}.cert.pem   /etc/ssl/certs/${DOMAIN}.cert.pem
sudo install -m 600 /tmp/${DOMAIN}.key.pem    /etc/ssl/private/${DOMAIN}.key.pem
sudo install -m 644 /tmp/pq-ca-chain.cert.pem /etc/ssl/certs/pq-ca-chain.cert.pem

# Install provider .so
sudo mkdir -p /usr/local/lib/ossl-modules
if [[ "$PROVIDER" == "liboqs" ]]; then
  sudo install -m 755 /tmp/oqsprovider.so /usr/local/lib/ossl-modules/oqsprovider.so
else
  sudo install -m 755 /tmp/symcryptprovider.so /usr/local/lib/ossl-modules/symcryptprovider.so
fi
sudo ldconfig

# Install provider OpenSSL conf
sudo install -m 644 /tmp/openssl-pq.cnf ${PROVIDER_DEST}

# Inject OPENSSL_CONF into Apache env
sudo mkdir -p /etc/apache2/envvars.d
echo '${APACHE_ENV_LINE}' | sudo tee /etc/apache2/envvars.d/pq-openssl.conf

# Install vhost
sudo install -m 644 /tmp/pq-ssl.conf /etc/apache2/sites-available/pq-ssl.conf
sudo a2enmod ssl headers
sudo a2ensite pq-ssl.conf
sudo apache2ctl configtest
sudo systemctl restart apache2
echo "Apache restarted"
REMOTE

rm -f "$VHOST_TMP" "$CERT_INT_CNF"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DONE issue-cert domain=${DOMAIN}" >> "$LOG"

echo
echo "============================================================"
echo "  SERVER CERTIFICATE DEPLOYED"
echo "============================================================"
echo "  Domain : ${DOMAIN}"
echo "  Web VM : ${WEB_IP}"
echo "  Cert   : /etc/ssl/certs/${DOMAIN}.cert.pem (on web VM)"
echo "  Chain  : /etc/ssl/certs/pq-ca-chain.cert.pem (on web VM)"
echo
echo "  Test from web VM:"
echo "    OPENSSL_CONF=${PROVIDER_DEST} \\"
echo "      openssl s_client -connect ${WEB_IP}:443 \\"
echo "        -groups x25519_mlkem768 -tls1_3 -showcerts"
echo "============================================================"
