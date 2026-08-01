#!/usr/bin/env bash
# =============================================================================
# 01-azure-infra.sh — Provision Azure infrastructure for PQ CA testing
#
# Creates:
#   - Resource group
#   - Virtual network (10.0.0.0/16) with two subnets: mgmt (10.0.1.0/24)
#     and web (10.0.2.0/24)
#   - NSG: SSH (22) from ADMIN_IP, HTTP/HTTPS (80/443) from internet to web
#   - Two Ubuntu 26.04 LTS VMs:
#       pq-ca-vm   — CA server (mgmt subnet, no public HTTPS)
#       pq-web-vm  — Apache web server (web subnet, public HTTP/HTTPS)
#   - Cloud-init user data injected into each VM
#
# Usage:
#   export ADMIN_IP="$(curl -s https://ifconfig.me)/32"
#   export PROVIDER=liboqs   # or: symcrypt
#   export ORG_NAME="MyOrg"
#   export ORG_COUNTRY="US"
#   export ORG_STATE="Washington"
#   ./01-azure-infra.sh
#
# Requirements: az CLI >= 2.60, jq
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment or edit here
# ---------------------------------------------------------------------------
PROVIDER="${PROVIDER:-liboqs}"          # liboqs | symcrypt
REGION="${REGION:-eastus}"
PREFIX="${PREFIX:-pq-ca}"
RG="${PREFIX}-rg"
VNET="${PREFIX}-vnet"
ADMIN_USER="${ADMIN_USER:-azureuser}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v5}"  # 4 vCPU/16 GB — needed to compile SymCrypt
UBUNTU_IMAGE="${UBUNTU_IMAGE:-Canonical:ubuntu-26_04-lts:server:latest}"

# CA certificate details (used in cloud-init)
ORG_NAME="${ORG_NAME:-TestOrg}"
ORG_COUNTRY="${ORG_COUNTRY:-US}"
ORG_STATE="${ORG_STATE:-Washington}"

# Your IP for SSH access — MUST be set
ADMIN_IP="${ADMIN_IP:-}"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
command -v az  &>/dev/null || error "az CLI is not installed — https://aka.ms/installazurecli"
command -v jq  &>/dev/null || error "jq is not installed (sudo apt install jq)"
az account show &>/dev/null || error "Not logged in to Azure — run: az login"

[[ "$PROVIDER" == "liboqs" || "$PROVIDER" == "symcrypt" ]] \
  || error "PROVIDER must be 'liboqs' or 'symcrypt', got: $PROVIDER"

if [[ -z "$ADMIN_IP" ]]; then
  ADMIN_IP="$(curl -s https://ifconfig.me)/32"
  info "Auto-detected ADMIN_IP: $ADMIN_IP"
fi

info "Deploying PQ CA test environment"
info "  Provider  : $PROVIDER"
info "  Region    : $REGION"
info "  Prefix    : $PREFIX"
info "  VM size   : $VM_SIZE"
info "  Admin IP  : $ADMIN_IP"
echo

# ---------------------------------------------------------------------------
# 1. Resource group
# ---------------------------------------------------------------------------
info "Creating resource group: $RG"
az group create --name "$RG" --location "$REGION" --output none
success "Resource group ready"

# ---------------------------------------------------------------------------
# 2. Virtual network and subnets
# ---------------------------------------------------------------------------
info "Creating VNet and subnets"
az network vnet create \
  --resource-group "$RG" \
  --name "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name mgmt-subnet \
  --subnet-prefix 10.0.1.0/24 \
  --output none

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name web-subnet \
  --address-prefix 10.0.2.0/24 \
  --output none
success "VNet ready"

# ---------------------------------------------------------------------------
# 3. Network Security Groups
# ---------------------------------------------------------------------------
info "Creating NSGs"

# --- CA NSG: SSH only from admin IP ---
CA_NSG="${PREFIX}-ca-nsg"
az network nsg create --resource-group "$RG" --name "$CA_NSG" --output none
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$CA_NSG" \
  --name AllowSSH --priority 100 \
  --protocol Tcp --direction Inbound --access Allow \
  --source-address-prefixes "$ADMIN_IP" \
  --destination-port-ranges 22 --output none

# --- Web NSG: SSH from admin, HTTP/HTTPS from internet ---
WEB_NSG="${PREFIX}-web-nsg"
az network nsg create --resource-group "$RG" --name "$WEB_NSG" --output none
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$WEB_NSG" \
  --name AllowSSH --priority 100 \
  --protocol Tcp --direction Inbound --access Allow \
  --source-address-prefixes "$ADMIN_IP" \
  --destination-port-ranges 22 --output none
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$WEB_NSG" \
  --name AllowHTTPS --priority 110 \
  --protocol Tcp --direction Inbound --access Allow \
  --source-address-prefixes '*' \
  --destination-port-ranges 443 --output none
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$WEB_NSG" \
  --name AllowHTTP --priority 120 \
  --protocol Tcp --direction Inbound --access Allow \
  --source-address-prefixes '*' \
  --destination-port-ranges 80 --output none
success "NSGs ready"

# ---------------------------------------------------------------------------
# 4. Public IPs
# ---------------------------------------------------------------------------
info "Creating public IPs"
az network public-ip create \
  --resource-group "$RG" --name "${PREFIX}-ca-pip" \
  --sku Standard --allocation-method Static \
  --dns-name "${PREFIX}-ca" --output none
az network public-ip create \
  --resource-group "$RG" --name "${PREFIX}-web-pip" \
  --sku Standard --allocation-method Static \
  --dns-name "${PREFIX}-web" --output none
success "Public IPs ready"

# ---------------------------------------------------------------------------
# 5. NICs
# ---------------------------------------------------------------------------
info "Creating NICs"
az network nic create \
  --resource-group "$RG" --name "${PREFIX}-ca-nic" \
  --vnet-name "$VNET" --subnet mgmt-subnet \
  --network-security-group "$CA_NSG" \
  --public-ip-address "${PREFIX}-ca-pip" \
  --output none
az network nic create \
  --resource-group "$RG" --name "${PREFIX}-web-nic" \
  --vnet-name "$VNET" --subnet web-subnet \
  --network-security-group "$WEB_NSG" \
  --public-ip-address "${PREFIX}-web-pip" \
  --output none
success "NICs ready"

# ---------------------------------------------------------------------------
# 6. Cloud-init files
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_INIT="${SCRIPT_DIR}/cloud-init-ca.yml"
WEB_INIT="${SCRIPT_DIR}/cloud-init-web.yml"

[[ -f "$CA_INIT"  ]] || error "Missing cloud-init file: $CA_INIT"
[[ -f "$WEB_INIT" ]] || error "Missing cloud-init file: $WEB_INIT"

# Substitute PROVIDER placeholder
CA_INIT_TMP="$(mktemp)"
WEB_INIT_TMP="$(mktemp)"
sed "s/{{PROVIDER}}/${PROVIDER}/g; \
     s/{{ORG_NAME}}/${ORG_NAME}/g; \
     s/{{ORG_COUNTRY}}/${ORG_COUNTRY}/g; \
     s/{{ORG_STATE}}/${ORG_STATE}/g" \
  "$CA_INIT" > "$CA_INIT_TMP"
cp "$WEB_INIT" "$WEB_INIT_TMP"

# ---------------------------------------------------------------------------
# 7. Virtual Machines
# ---------------------------------------------------------------------------
info "Creating CA VM (this takes 3–5 minutes)"
az vm create \
  --resource-group "$RG" \
  --name "${PREFIX}-ca-vm" \
  --nics "${PREFIX}-ca-nic" \
  --image "$UBUNTU_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --custom-data "@${CA_INIT_TMP}" \
  --output none
success "CA VM created"

info "Creating Web VM (this takes 3–5 minutes)"
az vm create \
  --resource-group "$RG" \
  --name "${PREFIX}-web-vm" \
  --nics "${PREFIX}-web-nic" \
  --image "$UBUNTU_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --custom-data "@${WEB_INIT_TMP}" \
  --output none
success "Web VM created"

rm -f "$CA_INIT_TMP" "$WEB_INIT_TMP"

# ---------------------------------------------------------------------------
# 8. Output connection info
# ---------------------------------------------------------------------------
CA_IP=$(az network public-ip show \
  --resource-group "$RG" --name "${PREFIX}-ca-pip" \
  --query ipAddress -o tsv)
WEB_IP=$(az network public-ip show \
  --resource-group "$RG" --name "${PREFIX}-web-pip" \
  --query ipAddress -o tsv)

echo
echo "============================================================"
echo "  DEPLOYMENT COMPLETE"
echo "============================================================"
echo "  CA VM  : ssh ${ADMIN_USER}@${CA_IP}"
echo "  Web VM : ssh ${ADMIN_USER}@${WEB_IP}"
echo "  Web URL: https://${WEB_IP}  (after cert deployment)"
echo
echo "  Provider selected: ${PROVIDER}"
echo "  Cloud-init scripts are running in the background on each VM."
echo "  Wait ~10-15 min for provider build to complete before running"
echo "  02-install-provider.sh or 03-build-ca.sh."
echo
echo "  Monitor cloud-init progress on CA VM:"
echo "    ssh ${ADMIN_USER}@${CA_IP} 'tail -f /var/log/cloud-init-output.log'"
echo "============================================================"

# Save IPs to a state file for later scripts
cat > "${SCRIPT_DIR}/.deploy-state" << EOF
CA_IP=${CA_IP}
WEB_IP=${WEB_IP}
ADMIN_USER=${ADMIN_USER}
PREFIX=${PREFIX}
RG=${RG}
PROVIDER=${PROVIDER}
EOF
success "State saved to .deploy-state — used by subsequent scripts"
