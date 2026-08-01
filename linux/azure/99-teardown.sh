#!/usr/bin/env bash
# =============================================================================
# 99-teardown.sh — Delete all Azure resources created by 01-azure-infra.sh
#
# Usage:
#   ./99-teardown.sh           # uses .deploy-state
#   RG=my-rg ./99-teardown.sh  # override resource group
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.deploy-state"

[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

RG="${RG:-}"
[[ -n "$RG" ]] || { echo "RG not set — source .deploy-state or set RG env var"; exit 1; }

echo "This will permanently delete resource group: ${RG}"
echo "Press Ctrl+C within 10 seconds to cancel..."
sleep 10

az group delete --name "$RG" --yes --no-wait
echo "Deletion initiated for resource group: ${RG}"
echo "Resources will be cleaned up within a few minutes."
echo
echo "To watch status:"
echo "  az group show --name ${RG} --query properties.provisioningState -o tsv"
