#!/usr/bin/env bash
# LumiTure GCP Onboarding — Cloud Shell wrapper
#
# Thin interactive wrapper around scripts/lumiture-gcp-onboard.sh,
# designed for use inside Cloud Shell's tutorial walkthrough.
#
# Usage:
#   bash onboard-wrapper.sh BILLING_ACCOUNT_ID EXPORT_PROJECT DETAILED_USAGE_DATASET PRICING_DATASET
#
# All 4 args are required. The tutorial collects them interactively in steps 2-3.

set -euo pipefail

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_blu='\033[0;34m'; c_off='\033[0m'
log() { printf "%b %s\n" "${c_blu}▸${c_off}" "$*" >&2; }
ok()  { printf "%b %s\n" "${c_grn}✅${c_off}" "$*" >&2; }
die() { printf "%b %s\n" "${c_red}✗${c_off}"  "$*" >&2; exit 1; }

# ── Arg parsing ──────────────────────────────────────────────────
[[ $# -eq 4 ]] || die "Need 4 args: BILLING_ACCOUNT_ID EXPORT_PROJECT DETAILED_USAGE_DATASET PRICING_DATASET"

BILLING_ACCOUNT_ID="$1"
EXPORT_PROJECT_ID="$2"
DETAILED_USAGE_DATASET="$3"
PRICING_DATASET="$4"

# ── Path to the underlying onboard script ────────────────────────
# In Cloud Shell, this repo is cloned to ~/cloudshell_open by default;
# adjust if your tutorial set cloudshell_workspace differently.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD="${SCRIPT_DIR}/lumiture-gcp-onboard.sh"

[[ -x "${ONBOARD}" ]] || die "Could not find ${ONBOARD} (or not executable). Make sure you cloned the full repo."

# ── Friendly summary ─────────────────────────────────────────────
echo ""
log "About to onboard your GCP billing data to LumiTure:"
echo "    Billing Account:        ${BILLING_ACCOUNT_ID}"
echo "    Export Project:         ${EXPORT_PROJECT_ID}"
echo "    Detailed Usage dataset: ${DETAILED_USAGE_DATASET}"
echo "    Pricing dataset:        ${PRICING_DATASET}"
echo ""
log "This will:"
echo "    1. Verify data is flowing in your billing export dataset"
echo "    2. Grant 'BigQuery Data Viewer' to lumiture-client@tw-rd-app-finops-prod...iam.gserviceaccount.com"
echo "    3. Print form values to paste into LumiTure's wizard"
echo ""
read -p "Continue? [Y/n] " confirm
[[ "${confirm:-Y}" =~ ^[Yy] ]] || die "Aborted."

# ── Run the underlying onboard script ────────────────────────────
log "Running discovery + freshness validation..."
echo ""

"${ONBOARD}" \
  --billing-account-id "${BILLING_ACCOUNT_ID}" \
  --export-project "${EXPORT_PROJECT_ID}" \
  --detailed-usage-dataset "${DETAILED_USAGE_DATASET}" \
  --pricing-dataset "${PRICING_DATASET}"

echo ""
ok "Done. Copy the JSON values above into the LumiTure wizard:"
echo "    👉 https://app.lumiture.ai/authorization/billing-integration/gcp"
echo ""
echo "After you submit, the status will flip to CONNECTED within ~15s,"
echo "and your dashboard will start populating in 5-15 minutes."
