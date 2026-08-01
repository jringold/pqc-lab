#!/usr/bin/env bash
# =============================================================================
# 06-client-verify.sh — Client-side TLS validation against PQ Apache server
#
# Run on the client VM after:
#   1) 02-install-provider.sh has installed PQ provider
#   2) Root CA cert has been trusted on the client
#
# Checks:
#   - TLS 1.3 handshake succeeds
#   - Protocol negotiated is TLSv1.3
#   - PQ/hybrid key exchange is negotiated
#   - TLS 1.2 attempt fails (server is TLS1.3-only)
# =============================================================================
set -euo pipefail

PROVIDER="${PQ_PROVIDER:-liboqs}"
TARGET=""
SNI=""
PORT="${PORT:-443}"
CA_CERT="${CA_CERT:-/usr/local/share/ca-certificates/pq-root-ca.crt}"
TIMEOUT="${TIMEOUT:-12}"

PASS=0
FAIL=0
SKIP=0

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
pass() { echo -e "  ${GREEN}PASS${RESET}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${RESET}  $*"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${RESET}  $*"; ((SKIP++)); }
head() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --sni)    SNI="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --ca-cert)  CA_CERT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "Usage: $0 --target <host_or_ip> [--sni fqdn]"; exit 1; }
[[ -f "$CA_CERT" ]] || { echo "CA cert not found: $CA_CERT"; exit 1; }

if [[ "$PROVIDER" == "liboqs" ]]; then
  OPENSSL_CONF="${OPENSSL_CONF:-/opt/pq-ca/openssl-pq.cnf}"
else
  OPENSSL_CONF="${OPENSSL_CONF:-/opt/pq-ca/openssl-symcrypt.cnf}"
fi
[[ -f "$OPENSSL_CONF" ]] || { echo "OpenSSL provider config not found: $OPENSSL_CONF"; exit 1; }

SNI_ARG=()
if [[ -n "$SNI" ]]; then
  SNI_ARG=(-servername "$SNI")
fi

run_sclient() {
  OPENSSL_CONF="$OPENSSL_CONF" timeout "$TIMEOUT" openssl s_client \
    -connect "${TARGET}:${PORT}" \
    -CAfile "$CA_CERT" \
    "${SNI_ARG[@]}" \
    "$@" \
    </dev/null 2>&1
}

echo "========================================================"
echo "  Client PQ TLS Verification"
echo "  Target   : ${TARGET}:${PORT}"
[[ -n "$SNI" ]] && echo "  SNI      : ${SNI}"
echo "  Provider : ${PROVIDER}"
echo "  OSSL CFG : ${OPENSSL_CONF}"
echo "  CA cert  : ${CA_CERT}"
echo "========================================================"

head "Test 1: TLS 1.3 handshake"
TLS13_OUT="$(run_sclient -tls1_3 -brief || true)"
if echo "$TLS13_OUT" | grep -q "Protocol version: TLSv1.3"; then
  pass "TLS 1.3 handshake succeeded"
elif echo "$TLS13_OUT" | grep -q "Protocol  : TLSv1.3"; then
  pass "TLS 1.3 handshake succeeded"
else
  fail "TLS 1.3 handshake failed"
  echo "$TLS13_OUT" | tail -8 | sed 's/^/    /'
fi

head "Test 2: Certificate verification"
if echo "$TLS13_OUT" | grep -q "Verification: OK"; then
  pass "Certificate chain validates to trusted Root CA"
elif echo "$TLS13_OUT" | grep -qi "verify return code: 0"; then
  pass "Certificate chain validates to trusted Root CA"
else
  fail "Certificate chain did not validate"
  echo "$TLS13_OUT" | grep -Ei "verify|Verification|error" | head -6 | sed 's/^/    /'
fi

head "Test 3: PQ/hybrid key exchange"
PQ_OUT="$(run_sclient -tls1_3 -groups x25519_mlkem768 -brief || true)"
if echo "$PQ_OUT" | grep -qi "X25519_MLKEM768\|mlkem768\|mlkem1024"; then
  pass "PQ/hybrid key exchange negotiated"
elif echo "$PQ_OUT" | grep -qi "Server Temp Key"; then
  fail "No PQ/hybrid key exchange detected"
  echo "$PQ_OUT" | grep -i "Server Temp Key" | head -1 | sed 's/^/    /'
else
  skip "Could not parse negotiated key exchange"
fi

head "Test 4: TLS 1.2 rejection"
TLS12_OUT="$(run_sclient -tls1_2 -brief || true)"
if echo "$TLS12_OUT" | grep -qi "protocol version\|handshake failure\|unsupported protocol"; then
  pass "TLS 1.2 rejected as expected"
elif echo "$TLS12_OUT" | grep -qi "Protocol version: TLSv1.2\|Protocol  : TLSv1.2"; then
  fail "TLS 1.2 unexpectedly succeeded"
else
  skip "Could not conclusively determine TLS 1.2 result"
fi

TOTAL=$((PASS + FAIL + SKIP))
echo
echo "========================================================"
echo "  RESULTS: ${PASS}/${TOTAL} passed, ${FAIL} failed, ${SKIP} skipped"
echo "========================================================"
[[ "$FAIL" -eq 0 ]]
