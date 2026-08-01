#!/usr/bin/env bash
# =============================================================================
# 00-remote-deploy.sh — Orchestrator: push scripts to VMs and run them
#
# This is the single entry-point. Run it from your local machine (with az CLI
# and SSH access) after 01-azure-infra.sh has completed.
#
# What it does:
#   1. Sources .deploy-state (output of 01-azure-infra.sh)
#   2. Waits for cloud-init to finish on all three VMs
#   3. Copies scripts 02-05 to the CA VM
#   4. Runs 02-install-provider.sh on the CA VM
#   5. Runs 03-build-ca.sh on the CA VM
#   6. Runs 04-issue-server-cert.sh on the CA VM (pushes certs to web VM)
#   7. Runs 05-verify-tls.sh on the CA VM against the web VM
#   8. Copies scripts 02 and 06 to the client VM
#   9. Runs 02-install-provider.sh on the client VM
#  10. Trusts Root CA cert on the client VM
#  11. Runs 06-client-verify.sh from client VM against web VM
#
# Usage:
#   ./01-azure-infra.sh                  # provision VMs
#   ./00-remote-deploy.sh                # deploy and verify
#
# Override any .deploy-state value via environment:
#   DOMAIN=mytest.example.com ./00-remote-deploy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.deploy-state"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

[[ -f "$STATE_FILE" ]] || error "State file not found: ${STATE_FILE}
  Run ./01-azure-infra.sh first."

source "$STATE_FILE"

# Allow environment overrides
CA_IP="${CA_IP}"
WEB_IP="${WEB_IP}"
CLIENT_IP="${CLIENT_IP}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
PROVIDER="${PROVIDER:-liboqs}"
DOMAIN="${DOMAIN:-$WEB_IP}"  # Default domain = web VM IP (IP-SAN cert)
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
CLOUD_INIT_TIMEOUT="${CLOUD_INIT_TIMEOUT:-900}"  # 15 min max

[[ -n "${CA_IP:-}" ]] || error "CA_IP missing in .deploy-state"
[[ -n "${WEB_IP:-}" ]] || error "WEB_IP missing in .deploy-state"
[[ -n "${CLIENT_IP:-}" ]] || error "CLIENT_IP missing in .deploy-state"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

ssh_ca()  { ssh  $SSH_OPTS "${ADMIN_USER}@${CA_IP}"  "$@"; }
scp_to_ca() { scp $SSH_OPTS "$1" "${ADMIN_USER}@${CA_IP}:$2"; }
ssh_client() { ssh $SSH_OPTS "${ADMIN_USER}@${CLIENT_IP}" "$@"; }
scp_to_client() { scp $SSH_OPTS "$1" "${ADMIN_USER}@${CLIENT_IP}:$2"; }

cleanup_staged_key() {
  ssh_ca "sudo rm -f /tmp/pq-web-ssh-key" >/dev/null 2>&1 || true
}
trap cleanup_staged_key EXIT

# ---------------------------------------------------------------------------
wait_for_cloud_init() {
  local HOST="$1"
  local LABEL="$2"
  local ELAPSED=0
  local INTERVAL=20

  info "Waiting for cloud-init on ${LABEL} (${HOST})..."
  while ! ssh $SSH_OPTS "${ADMIN_USER}@${HOST}" \
      "test -f /tmp/.cloud-init-web-status || test -f /tmp/.cloud-init-client-status || test -f /opt/pq-ca-setup/.cloud-init-status" \
      2>/dev/null; do
    if (( ELAPSED >= CLOUD_INIT_TIMEOUT )); then
      error "Cloud-init timed out on ${LABEL} after ${ELAPSED}s"
    fi
    printf "  Waiting... (%ds)\r" "$ELAPSED"
    sleep "$INTERVAL"
    (( ELAPSED += INTERVAL )) || true
  done
  success "Cloud-init complete on ${LABEL}"
}
# ---------------------------------------------------------------------------

echo
echo "================================================================"
echo "  PQ CA Remote Deployment Orchestrator"
echo "  CA VM   : ${ADMIN_USER}@${CA_IP}"
echo "  Web VM  : ${ADMIN_USER}@${WEB_IP}"
echo "  Client  : ${ADMIN_USER}@${CLIENT_IP}"
echo "  Provider: ${PROVIDER}"
echo "  Domain  : ${DOMAIN}"
echo "================================================================"

# ---------------------------------------------------------------------------
step "Step 1: Wait for cloud-init on all VMs"
wait_for_cloud_init "$CA_IP"  "CA VM"
wait_for_cloud_init "$WEB_IP" "Web VM"
wait_for_cloud_init "$CLIENT_IP" "Client VM"

# ---------------------------------------------------------------------------
step "Step 2: Copy scripts to CA VM"
for SCRIPT in 02-install-provider.sh 03-build-ca.sh 04-issue-server-cert.sh 05-verify-tls.sh; do
  scp_to_ca "${SCRIPT_DIR}/${SCRIPT}" "/tmp/${SCRIPT}"
done
ssh_ca "chmod +x /tmp/02-install-provider.sh /tmp/03-build-ca.sh \
                 /tmp/04-issue-server-cert.sh /tmp/05-verify-tls.sh"
success "Scripts uploaded"

# ---------------------------------------------------------------------------
step "Step 3: Install PQ provider on CA VM"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
success "Provider installed"

# ---------------------------------------------------------------------------
step "Step 4: Build CA hierarchy"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} \
             ORG_NAME='${ORG_NAME:-TestOrg}' \
             ORG_COUNTRY='${ORG_COUNTRY:-US}' \
             ORG_STATE='${ORG_STATE:-Washington}' \
             bash /tmp/03-build-ca.sh"
success "CA hierarchy built"

# ---------------------------------------------------------------------------
step "Step 5: Issue server certificate and deploy to web VM"
[[ -f "$SSH_KEY" ]] || error "SSH key not found at ${SSH_KEY}. Set SSH_KEY to a readable private key."
scp_to_ca "$SSH_KEY" "/tmp/pq-web-ssh-key"
ssh_ca "chmod 600 /tmp/pq-web-ssh-key"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} \
             ORG_NAME='${ORG_NAME:-TestOrg}' \
             ORG_COUNTRY='${ORG_COUNTRY:-US}' \
             ORG_STATE='${ORG_STATE:-Washington}' \
             bash /tmp/04-issue-server-cert.sh \
               --domain ${DOMAIN} \
               --web-ip  ${WEB_IP} \
               --web-user ${ADMIN_USER} \
               --ssh-key /tmp/pq-web-ssh-key"
ssh_ca "sudo rm -f /tmp/pq-web-ssh-key"
success "Server cert deployed and Apache configured"

# ---------------------------------------------------------------------------
step "Step 6: Run PQ TLS verification"
ssh_ca "PQ_PROVIDER=${PROVIDER} \
        bash /tmp/05-verify-tls.sh \
          --target ${WEB_IP} \
          --ca-cert /opt/pq-ca/root-ca/certs/root-ca.cert.pem"

# ---------------------------------------------------------------------------
step "Step 7: Copy scripts to Client VM"
for SCRIPT in 02-install-provider.sh 06-client-verify.sh; do
  scp_to_client "${SCRIPT_DIR}/${SCRIPT}" "/tmp/${SCRIPT}"
done
ssh_client "chmod +x /tmp/02-install-provider.sh /tmp/06-client-verify.sh"
success "Client scripts uploaded"

# ---------------------------------------------------------------------------
step "Step 8: Install PQ provider on Client VM"
ssh_client "sudo mkdir -p /opt/pq-ca /opt/pq-ca-setup"
ssh_client "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
success "Client provider installed"

# ---------------------------------------------------------------------------
step "Step 9: Trust Root CA on Client VM"
TMP_ROOT_CA="$(mktemp)"
ssh_ca "sudo cat /opt/pq-ca/root-ca/certs/root-ca.cert.pem" > "$TMP_ROOT_CA"
scp_to_client "$TMP_ROOT_CA" "/tmp/pq-root-ca.crt"
rm -f "$TMP_ROOT_CA"
ssh_client "sudo cp /tmp/pq-root-ca.crt /usr/local/share/ca-certificates/pq-root-ca.crt && sudo update-ca-certificates"
success "Root CA trusted on client"

# ---------------------------------------------------------------------------
step "Step 10: Run client-side TLS verification"
ssh_client "PQ_PROVIDER=${PROVIDER} bash /tmp/06-client-verify.sh \
              --target ${WEB_IP} \
              --ca-cert /usr/local/share/ca-certificates/pq-root-ca.crt"

echo
echo "================================================================"
echo "  DEPLOYMENT COMPLETE"
echo "================================================================"
echo "  CA VM  : ssh ${ADMIN_USER}@${CA_IP}"
echo "  Web VM : https://${WEB_IP}  (self-signed PQ cert)"
echo "  Client : ssh ${ADMIN_USER}@${CLIENT_IP}"
echo "  Client GUI: RDP to ${CLIENT_IP}:3389 using ${ADMIN_USER}"
echo
echo "  To add your Root CA to local trust (Linux):"
echo "    scp ${ADMIN_USER}@${CA_IP}:/opt/pq-ca/root-ca/certs/root-ca.cert.pem /tmp/"
echo "    sudo cp /tmp/root-ca.cert.pem /usr/local/share/ca-certificates/pq-root-ca.crt"
echo "    sudo update-ca-certificates"
echo
echo "  To teardown all resources:"
echo "    az group delete --name ${RG} --yes --no-wait"
echo "================================================================"
