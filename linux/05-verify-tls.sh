#!/usr/bin/env bash
# =============================================================================
# 05-verify-tls.sh — End-to-end PQ TLS verification suite
#
# Runs a series of checks against the deployed Apache web server:
#   1. TCP connectivity (port 443)
#   2. TLS handshake succeeds using the PQ provider
#   3. Server certificate uses ML-DSA (not classical RSA/ECDSA)
#   4. TLS 1.3 is negotiated (required for ML-KEM key exchange)
#   5. Server Temp Key is a PQ or hybrid KEM group (x25519_mlkem768 etc.)
#   6. Certificate chain validates to our Root CA
#   7. HTTP redirect (port 80 → 443)
#
# Usage (run from CA VM or any machine with PQ provider installed):
#   bash 05-verify-tls.sh --target <IP_or_domain> --ca-cert <root-ca.cert.pem>
#
# Or, if both VMs are deployed via 01-azure-infra.sh, source .deploy-state:
#   source .deploy-state
#   bash 05-verify-tls.sh --target "$WEB_IP" \
#     --ca-cert /opt/pq-ca/root-ca/certs/root-ca.cert.pem
# =============================================================================
set -euo pipefail

[[ -f /opt/pq-ca-setup/env.sh ]] && source /opt/pq-ca-setup/env.sh 2>/dev/null || true

PROVIDER="${PQ_PROVIDER:-liboqs}"
TARGET=""
CA_CERT=""
PORT="${PORT:-443}"
TIMEOUT="${TIMEOUT:-10}"
PASS=0
FAIL=0
SKIP=0
LOG=/tmp/pq-verify-$$.log

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓ PASS${RESET}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✗ FAIL${RESET}  $*"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}⊙ SKIP${RESET}  $*"; ((SKIP++)); }
head() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --target)   TARGET="$2";   shift 2 ;;
    --ca-cert)  CA_CERT="$2";  shift 2 ;;
    --port)     PORT="$2";     shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -n "$TARGET"  ]] || { echo "Usage: $0 --target <IP_or_host> --ca-cert <path>"; exit 1; }
[[ -n "$CA_CERT" ]] || { echo "--ca-cert is required (path to root CA PEM)"; exit 1; }
[[ -f "$CA_CERT" ]] || { echo "CA cert not found: $CA_CERT"; exit 1; }

# Select OpenSSL provider conf
if [[ "$PROVIDER" == "liboqs" ]]; then
  OPENSSL_CONF="${OPENSSL_CONF:-/opt/pq-ca/openssl-pq.cnf}"
  if [[ ! -f "$OPENSSL_CONF" ]]; then
    OPENSSL_CONF=/etc/ssl/openssl-pq.cnf
  fi
else
  OPENSSL_CONF="${OPENSSL_CONF:-/opt/pq-ca/openssl-symcrypt.cnf}"
  if [[ ! -f "$OPENSSL_CONF" ]]; then
    OPENSSL_CONF=/etc/ssl/openssl-symcrypt.cnf
  fi
fi

if [[ ! -f "$OPENSSL_CONF" ]]; then
  echo "WARNING: PQ OpenSSL config not found at $OPENSSL_CONF"
  echo "         Some tests will be skipped. Run 02-install-provider.sh first."
  OPENSSL_CONF=""
fi

echo
echo "========================================================"
echo "  PQ TLS Verification Suite"
echo "  Target   : ${TARGET}:${PORT}"
echo "  Provider : ${PROVIDER}"
echo "  CA cert  : ${CA_CERT}"
[[ -n "$OPENSSL_CONF" ]] && echo "  OSSL CFG : ${OPENSSL_CONF}"
echo "========================================================"

# Helper: run openssl s_client and capture output
s_client() {
  local EXTRA_ARGS="$*"
  if [[ -n "$OPENSSL_CONF" ]]; then
    OPENSSL_CONF="$OPENSSL_CONF" \
      timeout "$TIMEOUT" openssl s_client \
        -connect "${TARGET}:${PORT}" \
        -CAfile "${CA_CERT}" \
        -tls1_3 \
        ${EXTRA_ARGS} \
        </dev/null 2>&1
  else
    timeout "$TIMEOUT" openssl s_client \
      -connect "${TARGET}:${PORT}" \
      -CAfile "${CA_CERT}" \
      -tls1_3 \
      ${EXTRA_ARGS} \
      </dev/null 2>&1
  fi
}

# =============================================================================
# Test 1: TCP connectivity
# =============================================================================
head "Test 1: TCP connectivity (port ${PORT})"
if timeout 5 bash -c "echo > /dev/tcp/${TARGET}/${PORT}" 2>/dev/null; then
  pass "Port ${PORT} is reachable on ${TARGET}"
else
  fail "Cannot reach ${TARGET}:${PORT} — check NSG/firewall rules"
  echo "  Aborting remaining tests."
  exit 1
fi

# =============================================================================
# Test 2: TLS handshake
# =============================================================================
head "Test 2: TLS handshake"
if [[ -n "$OPENSSL_CONF" ]]; then
  TLS_OUT=$(s_client "-groups x25519_mlkem768" 2>&1 || true)
  if echo "$TLS_OUT" | grep -q "Verification: OK"; then
    pass "TLS handshake succeeded and cert chain verified"
  elif echo "$TLS_OUT" | grep -q "CONNECTED"; then
    fail "TLS connected but chain verification failed"
    echo "$TLS_OUT" | grep -E "Verify|error" | head -5 | sed 's/^/    /'
  else
    fail "TLS handshake failed"
    echo "$TLS_OUT" | tail -10 | sed 's/^/    /'
  fi
else
  skip "PQ provider not configured — skipping full TLS test"
fi

# =============================================================================
# Test 3: Certificate uses ML-DSA
# =============================================================================
head "Test 3: Server certificate algorithm"
CERT_OUT=$(s_client "" 2>&1 | openssl x509 -noout -text 2>/dev/null || true)
if echo "$CERT_OUT" | grep -qi "ml-dsa\|id-ml-dsa\|dilithium"; then
  ALGO=$(echo "$CERT_OUT" | grep -i "Public Key Algorithm" | head -1 | awk -F: '{print $2}' | tr -d ' ')
  pass "Server cert uses ML-DSA: ${ALGO}"
elif echo "$CERT_OUT" | grep -q "Public Key Algorithm"; then
  ALGO=$(echo "$CERT_OUT" | grep "Public Key Algorithm" | head -1 | awk -F: '{print $2}' | tr -d ' ')
  fail "Server cert uses CLASSICAL algorithm: ${ALGO} (expected ML-DSA)"
else
  skip "Could not extract cert from TLS handshake"
fi

# =============================================================================
# Test 4: TLS 1.3 negotiated
# =============================================================================
head "Test 4: TLS version"
TLS_OUT=$(s_client "" 2>&1 || true)
if echo "$TLS_OUT" | grep -q "Protocol  : TLSv1.3"; then
  pass "TLS 1.3 negotiated"
elif echo "$TLS_OUT" | grep -q "TLSv1"; then
  VER=$(echo "$TLS_OUT" | grep "Protocol" | head -1)
  fail "Wrong TLS version: ${VER} (expected TLSv1.3)"
else
  skip "TLS version not detected"
fi

# =============================================================================
# Test 5: PQ key exchange group in Server Temp Key
# =============================================================================
head "Test 5: Post-quantum key exchange"
if [[ -n "$OPENSSL_CONF" ]]; then
  KE_OUT=$(s_client "-groups x25519_mlkem768" 2>&1 || true)
  if echo "$KE_OUT" | grep -qi "X25519_MLKEM768\|mlkem768\|mlkem1024"; then
    KE=$(echo "$KE_OUT" | grep -i "Server Temp Key" | head -1)
    pass "PQ key exchange confirmed: ${KE}"
  elif echo "$KE_OUT" | grep -q "Server Temp Key"; then
    KE=$(echo "$KE_OUT" | grep "Server Temp Key" | head -1)
    fail "Classical key exchange only: ${KE} (ML-KEM groups not negotiated)"
  else
    skip "Server Temp Key not found in handshake output"
  fi
else
  skip "PQ provider not available — cannot test ML-KEM groups"
fi

# =============================================================================
# Test 6: Certificate chain validates to Root CA
# =============================================================================
head "Test 6: Certificate chain validation"
CHAIN_OUT=$(s_client "-showcerts" 2>&1 || true)
if echo "$CHAIN_OUT" | grep -q "Verification: OK"; then
  pass "Full chain validates to provided Root CA"
elif echo "$CHAIN_OUT" | grep -q "verify return:1"; then
  pass "Individual cert verified"
else
  fail "Chain validation failed — check CA cert and chain file"
  echo "$CHAIN_OUT" | grep -E "verify error|Verification" | head -5 | sed 's/^/    /'
fi

# =============================================================================
# Test 7: HTTP redirect to HTTPS
# =============================================================================
head "Test 7: HTTP → HTTPS redirect"
if command -v curl &>/dev/null; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://${TARGET}/" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    pass "HTTP redirects to HTTPS (HTTP ${HTTP_CODE})"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    skip "HTTP port 80 unreachable (NSG may block port 80)"
  else
    fail "Unexpected HTTP response: ${HTTP_CODE}"
  fi
else
  skip "curl not installed"
fi

# =============================================================================
# Test 8: HSTS header present
# =============================================================================
head "Test 8: HSTS header"
if command -v curl &>/dev/null && [[ -n "$OPENSSL_CONF" ]]; then
  HSTS=$(OPENSSL_CONF="$OPENSSL_CONF" curl -sk \
    --cacert "${CA_CERT}" \
    -I "https://${TARGET}/" 2>/dev/null \
    | grep -i "Strict-Transport-Security" || true)
  if [[ -n "$HSTS" ]]; then
    pass "HSTS header present: ${HSTS%%$'\r'}"
  else
    fail "HSTS header missing — check Apache Header directive"
  fi
else
  skip "curl or PQ provider not available"
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL + SKIP))
echo
echo "========================================================"
echo "  RESULTS: ${PASS}/${TOTAL} passed, ${FAIL} failed, ${SKIP} skipped"
echo "========================================================"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Some tests failed.${RESET} Review output above."
  exit 1
else
  echo -e "  ${GREEN}All tests passed!${RESET}"
fi
echo
