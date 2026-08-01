#!/usr/bin/env bash
# =============================================================================
# 00-remote-deploy.sh — Hyper-V orchestrator for PQ CA deployment
#
# Run this after 01-hyperv-infra.ps1 from a shell that has ssh/scp.
# It reuses the same CA/Web/Client Linux scripts as the Azure flow.
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

[[ -f "$STATE_FILE" ]] || error "State file not found: ${STATE_FILE}. Run 01-hyperv-infra.ps1 first."
source "$STATE_FILE"

CA_IP="${CA_IP:-}"
WEB_IP="${WEB_IP:-}"
CLIENT_IP="${CLIENT_IP:-}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
PROVIDER="${PROVIDER:-liboqs}"
DOMAIN="${DOMAIN:-$WEB_IP}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_TIMEOUT="${SSH_TIMEOUT:-900}"

[[ -n "$CA_IP" ]] || error "CA_IP missing in .deploy-state"
[[ -n "$WEB_IP" ]] || error "WEB_IP missing in .deploy-state"
[[ -n "$CLIENT_IP" ]] || error "CLIENT_IP missing in .deploy-state"
[[ "$PROVIDER" == "liboqs" || "$PROVIDER" == "symcrypt" ]] || error "PROVIDER must be liboqs or symcrypt"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

ssh_ca()      { ssh $SSH_OPTS "${ADMIN_USER}@${CA_IP}" "$@"; }
ssh_client()  { ssh $SSH_OPTS "${ADMIN_USER}@${CLIENT_IP}" "$@"; }
scp_to_ca()   { scp $SSH_OPTS "$1" "${ADMIN_USER}@${CA_IP}:$2"; }
scp_to_client(){ scp $SSH_OPTS "$1" "${ADMIN_USER}@${CLIENT_IP}:$2"; }

cleanup_staged_key() {
  ssh_ca "sudo rm -f /tmp/pq-web-ssh-key" >/dev/null 2>&1 || true
}
trap cleanup_staged_key EXIT

wait_for_ssh() {
  local HOST="$1"
  local LABEL="$2"
  local elapsed=0
  local interval=15

  info "Waiting for SSH on ${LABEL} (${HOST})..."
  while ! ssh $SSH_OPTS "${ADMIN_USER}@${HOST}" "echo ok" >/dev/null 2>&1; do
    if (( elapsed >= SSH_TIMEOUT )); then
      error "SSH timeout on ${LABEL} after ${elapsed}s"
    fi
    printf "  Waiting... (%ds)\r" "$elapsed"
    sleep "$interval"
    (( elapsed += interval )) || true
  done
  success "SSH ready on ${LABEL}"
}

echo
echo "================================================================"
echo "  PQ CA Hyper-V Remote Deployment"
echo "  CA VM   : ${ADMIN_USER}@${CA_IP}"
echo "  Web VM  : ${ADMIN_USER}@${WEB_IP}"
echo "  Client  : ${ADMIN_USER}@${CLIENT_IP}"
echo "  Provider: ${PROVIDER}"
echo "  Domain  : ${DOMAIN}"
echo "================================================================"

step "Step 1: Wait for SSH on all VMs"
wait_for_ssh "$CA_IP" "CA VM"
wait_for_ssh "$WEB_IP" "Web VM"
wait_for_ssh "$CLIENT_IP" "Client VM"

step "Step 2: Copy scripts to CA VM"
for script in 02-install-provider.sh 03-build-ca.sh 04-issue-server-cert.sh 05-verify-tls.sh; do
  scp_to_ca "${SCRIPT_DIR}/${script}" "/tmp/${script}"
done
ssh_ca "chmod +x /tmp/02-install-provider.sh /tmp/03-build-ca.sh /tmp/04-issue-server-cert.sh /tmp/05-verify-tls.sh"
success "CA scripts uploaded"

step "Step 3: Install provider on CA VM"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
success "Provider installed on CA VM"

step "Step 4: Build CA hierarchy"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} ORG_NAME='${ORG_NAME:-TestOrg}' ORG_COUNTRY='${ORG_COUNTRY:-US}' ORG_STATE='${ORG_STATE:-Washington}' bash /tmp/03-build-ca.sh"
success "CA hierarchy built"

step "Step 5: Issue cert and deploy to web VM"
[[ -f "$SSH_KEY" ]] || error "SSH key not found at ${SSH_KEY}. Set SSH_KEY to a readable private key."
scp_to_ca "$SSH_KEY" "/tmp/pq-web-ssh-key"
ssh_ca "chmod 600 /tmp/pq-web-ssh-key"
ssh_ca "sudo PQ_PROVIDER=${PROVIDER} ORG_NAME='${ORG_NAME:-TestOrg}' ORG_COUNTRY='${ORG_COUNTRY:-US}' ORG_STATE='${ORG_STATE:-Washington}' bash /tmp/04-issue-server-cert.sh --domain ${DOMAIN} --web-ip ${WEB_IP} --web-user ${ADMIN_USER} --ssh-key /tmp/pq-web-ssh-key"
ssh_ca "sudo rm -f /tmp/pq-web-ssh-key"
success "Server cert deployed"

step "Step 6: Verify from CA VM"
ssh_ca "PQ_PROVIDER=${PROVIDER} bash /tmp/05-verify-tls.sh --target ${WEB_IP} --ca-cert /opt/pq-ca/root-ca/certs/root-ca.cert.pem"

step "Step 7: Install provider on client VM"
scp_to_client "${SCRIPT_DIR}/02-install-provider.sh" "/tmp/02-install-provider.sh"
scp_to_client "${SCRIPT_DIR}/06-client-verify.sh" "/tmp/06-client-verify.sh"
ssh_client "chmod +x /tmp/02-install-provider.sh /tmp/06-client-verify.sh"
ssh_client "sudo mkdir -p /opt/pq-ca /opt/pq-ca-setup"
ssh_client "sudo PQ_PROVIDER=${PROVIDER} bash /tmp/02-install-provider.sh"
success "Provider installed on client VM"

step "Step 8: Trust Root CA on client VM"
tmp_root="$(mktemp)"
ssh_ca "sudo cat /opt/pq-ca/root-ca/certs/root-ca.cert.pem" > "$tmp_root"
scp_to_client "$tmp_root" "/tmp/pq-root-ca.crt"
rm -f "$tmp_root"
ssh_client "sudo cp /tmp/pq-root-ca.crt /usr/local/share/ca-certificates/pq-root-ca.crt && sudo update-ca-certificates"
success "Root CA trusted on client VM"

step "Step 9: Verify from client VM"
ssh_client "PQ_PROVIDER=${PROVIDER} bash /tmp/06-client-verify.sh --target ${WEB_IP} --ca-cert /usr/local/share/ca-certificates/pq-root-ca.crt"

echo
echo "================================================================"
echo "  DEPLOYMENT COMPLETE"
echo "================================================================"
echo "  CA VM    : ssh ${ADMIN_USER}@${CA_IP}"
echo "  Web VM   : https://${WEB_IP}"
echo "  Client VM: ssh ${ADMIN_USER}@${CLIENT_IP}"
echo "================================================================"
