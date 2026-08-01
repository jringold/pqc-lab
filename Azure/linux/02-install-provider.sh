#!/usr/bin/env bash
# =============================================================================
# 02-install-provider.sh — Build and install the PQ OpenSSL provider
#
# Reads provider choice from .deploy-state (set by 01-azure-infra.sh)
# or from the PQ_PROVIDER environment variable.
#
# Run this on the CA VM:
#   scp 02-install-provider.sh azureuser@<CA_IP>:/tmp/
#   ssh azureuser@<CA_IP> 'sudo bash /tmp/02-install-provider.sh'
#
# Or use 00-remote-deploy.sh to push and run automatically.
#
# Timeline:
#   LibOQS:   ~5 min  (cmake + ninja build)
#   SymCrypt: ~15 min (larger codebase, submodule init)
# =============================================================================
set -euo pipefail

PROVIDER="${PQ_PROVIDER:-liboqs}"
LOG=/var/log/pq-setup.log

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root (sudo bash $0)"
[[ "$PROVIDER" == "liboqs" || "$PROVIDER" == "symcrypt" ]] \
  || error "PROVIDER must be 'liboqs' or 'symcrypt'"

info "=== PQ Provider Installation: ${PROVIDER} ==="
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] START install-provider provider=${PROVIDER}" >> "$LOG"

mkdir -p /usr/local/src

# =============================================================================
# OPTION A — LibOQS + OQS-Provider
# =============================================================================
if [[ "$PROVIDER" == "liboqs" ]]; then

  # --- A.1 Build liboqs ---
  info "Cloning liboqs..."
  if [[ ! -d /usr/local/src/liboqs ]]; then
    git clone -b main https://github.com/open-quantum-safe/liboqs.git \
      /usr/local/src/liboqs
  else
    warn "liboqs already cloned, pulling latest"
    git -C /usr/local/src/liboqs pull --ff-only || true
  fi

  info "Building liboqs (this takes ~3 min)..."
  mkdir -p /usr/local/src/liboqs/build
  cmake -S /usr/local/src/liboqs -B /usr/local/src/liboqs/build \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=ON \
    -DOQS_USE_OPENSSL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/liboqs/build 2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/liboqs/build install 2>&1 | tee -a "$LOG"
  ldconfig
  success "liboqs installed"

  # Verify
  ls /usr/local/lib/liboqs.so* > /dev/null \
    || error "liboqs.so not found after install"

  # --- A.2 Build oqs-provider ---
  info "Cloning oqs-provider..."
  if [[ ! -d /usr/local/src/oqs-provider ]]; then
    git clone https://github.com/open-quantum-safe/oqs-provider.git \
      /usr/local/src/oqs-provider
  else
    warn "oqs-provider already cloned, pulling latest"
    git -C /usr/local/src/oqs-provider pull --ff-only || true
  fi

  info "Building oqs-provider..."
  mkdir -p /usr/local/src/oqs-provider/build
  cmake -S /usr/local/src/oqs-provider -B /usr/local/src/oqs-provider/build \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -Dliboqs_DIR=/usr/local/lib/cmake/liboqs \
    2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/oqs-provider/build 2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/oqs-provider/build install 2>&1 | tee -a "$LOG"
  ldconfig
  success "oqs-provider installed"

  # Verify provider .so
  [[ -f /usr/local/lib/ossl-modules/oqsprovider.so ]] \
    || error "oqsprovider.so not found — build may have failed"

  # --- A.3 Write OpenSSL config ---
  info "Writing /opt/pq-ca/openssl-pq.cnf"
  tee /opt/pq-ca/openssl-pq.cnf > /dev/null << 'EOF'
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

  # Verify algorithms
  info "Verifying ML-DSA and ML-KEM are available..."
  OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
    openssl list -signature-algorithms 2>/dev/null | grep -i "ml-dsa" \
    || error "ML-DSA not listed — oqs-provider may not be loaded"
  OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf \
    openssl list -kem-algorithms 2>/dev/null | grep -i "ml-kem" \
    || error "ML-KEM not listed — oqs-provider may not be loaded"
  success "LibOQS provider verified: ML-DSA and ML-KEM available"

  echo "OPENSSL_CONF=/opt/pq-ca/openssl-pq.cnf" >> /etc/profile.d/pq-provider.sh

fi  # end liboqs

# =============================================================================
# OPTION B — SymCrypt + SymCrypt-OpenSSL Provider
# =============================================================================
if [[ "$PROVIDER" == "symcrypt" ]]; then

  # --- B.1 Extra build deps ---
  info "Installing SymCrypt build dependencies..."
  apt-get install -y cmake ninja-build python3 python3-pip \
    libssl-dev gcc g++ pkg-config 2>&1 | tail -5

  # --- B.2 Build SymCrypt ---
  info "Cloning SymCrypt..."
  if [[ ! -d /usr/local/src/SymCrypt ]]; then
    git clone https://github.com/microsoft/SymCrypt.git \
      /usr/local/src/SymCrypt
  else
    warn "SymCrypt already cloned, pulling latest"
    git -C /usr/local/src/SymCrypt pull --ff-only || true
  fi

  info "Initializing jitterentropy submodule (required for FIPS entropy)..."
  git -C /usr/local/src/SymCrypt submodule update --init

  info "Building SymCrypt (this takes ~10 min)..."
  cd /usr/local/src/SymCrypt
  python3 scripts/build.py cmake release --arch amd64 2>&1 | tee -a "$LOG"

  # Copy shared library
  SYMCRYPT_SO=$(find /usr/local/src/SymCrypt/bin/release -name "libsymcrypt.so.*" | head -1)
  [[ -n "$SYMCRYPT_SO" ]] || error "libsymcrypt.so not found after build"
  cp "$SYMCRYPT_SO" /usr/local/lib/
  SONAME=$(basename "$SYMCRYPT_SO")
  ln -sf "/usr/local/lib/${SONAME}" /usr/local/lib/libsymcrypt.so
  ldconfig
  success "SymCrypt installed: ${SONAME}"

  # --- B.3 Build SymCrypt-OpenSSL provider ---
  info "Cloning SymCrypt-OpenSSL..."
  if [[ ! -d /usr/local/src/SymCrypt-OpenSSL ]]; then
    git clone https://github.com/microsoft/SymCrypt-OpenSSL.git \
      /usr/local/src/SymCrypt-OpenSSL
  else
    warn "SymCrypt-OpenSSL already cloned, pulling latest"
    git -C /usr/local/src/SymCrypt-OpenSSL pull --ff-only || true
  fi

  info "Building SymCrypt-OpenSSL provider..."
  mkdir -p /usr/local/src/SymCrypt-OpenSSL/build
  cmake -S /usr/local/src/SymCrypt-OpenSSL \
        -B /usr/local/src/SymCrypt-OpenSSL/build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSYMCRYPT_ROOT=/usr/local/src/SymCrypt \
    2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/SymCrypt-OpenSSL/build 2>&1 | tee -a "$LOG"
  ninja -C /usr/local/src/SymCrypt-OpenSSL/build install 2>&1 | tee -a "$LOG"
  ldconfig
  success "SymCrypt-OpenSSL provider installed"

  [[ -f /usr/local/lib/ossl-modules/symcryptprovider.so ]] \
    || error "symcryptprovider.so not found — build may have failed"

  # --- B.4 Write OpenSSL config ---
  info "Writing /opt/pq-ca/openssl-symcrypt.cnf"
  tee /opt/pq-ca/openssl-symcrypt.cnf > /dev/null << 'EOF'
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

  # Verify algorithms
  info "Verifying ML-DSA and ML-KEM are available..."
  OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf \
    openssl list -signature-algorithms 2>/dev/null | grep -i "ml-dsa" \
    || error "ML-DSA not listed — symcryptprovider may not be loaded"
  OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf \
    openssl list -kem-algorithms 2>/dev/null | grep -i "ml-kem" \
    || error "ML-KEM not listed — symcryptprovider may not be loaded"
  success "SymCrypt provider verified: ML-DSA and ML-KEM available"

  echo "OPENSSL_CONF=/opt/pq-ca/openssl-symcrypt.cnf" >> /etc/profile.d/pq-provider.sh

fi  # end symcrypt

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DONE install-provider provider=${PROVIDER}" >> "$LOG"
echo "PROVIDER_INSTALLED=1" >> /opt/pq-ca-setup/.cloud-init-status
success "=== Provider installation complete: ${PROVIDER} ==="
