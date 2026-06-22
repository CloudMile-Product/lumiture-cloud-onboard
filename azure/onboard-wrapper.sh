#!/usr/bin/env bash
# LumiTure Azure Onboarding — Cloud Shell wrapper
#
# Thin interactive wrapper around lumiture-azure-onboard.sh, designed for use
# inside Azure Cloud Shell's tutorial walkthrough.
#
# Usage:
#   bash onboard-wrapper.sh SUBSCRIPTION_ID STORAGE_ACCOUNT STORAGE_RG [LUMITURE_APP_ID]
#
# The first 3 args are required. LUMITURE_APP_ID is optional (defaults to the
# prod value baked into lumiture-azure-onboard.sh). The tutorial collects these
# interactively in steps 2-3.

set -euo pipefail

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_blu='\033[0;34m'; c_off='\033[0m'
log() { printf "%b %s\n" "${c_blu}▸${c_off}" "$*" >&2; }
ok()  { printf "%b %s\n" "${c_grn}✅${c_off}" "$*" >&2; }
die() { printf "%b %s\n" "${c_red}✗${c_off}"  "$*" >&2; exit 1; }

# ── Arg parsing ──────────────────────────────────────────────────
[[ $# -ge 3 ]] || die "Need 3+ args: SUBSCRIPTION_ID STORAGE_ACCOUNT STORAGE_RG [LUMITURE_APP_ID]"

SUBSCRIPTION_ID="$1"
STORAGE_ACCOUNT="$2"
STORAGE_RG="$3"
LUMITURE_APP_ID="${4:-}"

# ── Path to the underlying onboard script ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD="${SCRIPT_DIR}/lumiture-azure-onboard.sh"
[[ -x "${ONBOARD}" ]] || die "Could not find ${ONBOARD} (or not executable). Make sure you cloned the full repo."

# ── Friendly summary ─────────────────────────────────────────────
echo ""
log "About to onboard your Azure billing data to LumiTure:"
echo "    Subscription:    ${SUBSCRIPTION_ID}"
echo "    Storage account: ${STORAGE_ACCOUNT}  (resource group ${STORAGE_RG})"
echo ""
log "This will:"
echo "    1. Verify LumiTure's service principal is consented in your tenant"
echo "    2. Ensure the storage account + container for the cost export exist"
echo "    3. Grant 'Cost Management Reader' (subscription) + 'Storage Blob Data Reader' (storage) to LumiTure"
echo "    4. Create a daily Cost Management export"
echo "    5. Print form values to enter in LumiTure's wizard"
echo ""
read -p "Continue? [Y/n] " confirm
[[ "${confirm:-Y}" =~ ^[Yy] ]] || die "Aborted."

echo ""
log "Running onboarding..."
echo ""

ARGS=( --subscription-id "${SUBSCRIPTION_ID}"
       --storage-account "${STORAGE_ACCOUNT}"
       --storage-rg "${STORAGE_RG}" )
[[ -n "${LUMITURE_APP_ID}" ]] && ARGS+=( --lumiture-app-id "${LUMITURE_APP_ID}" )

"${ONBOARD}" "${ARGS[@]}"

echo ""
ok "Done. Enter the JSON values above into the LumiTure wizard:"
echo "    👉 https://app.lumiture.ai/authorization/billing-data-integration/azure"
echo ""
echo "After you submit, the subscription status flips to CONNECTED once the first"
echo "subscription sync runs; billing data appears after the export's first daily"
echo "run lands in storage (~24h) and is transferred to BigQuery."
