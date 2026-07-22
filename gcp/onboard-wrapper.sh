#!/usr/bin/env bash
# LumiTure GCP Onboarding — Cloud Shell wrapper
#
# Thin interactive wrapper around init.sh,
# designed for use inside Cloud Shell's tutorial walkthrough.
#
# Usage:
#   bash onboard-wrapper.sh                                                    # full auto-detect
#   bash onboard-wrapper.sh BILLING_ACCOUNT_ID                                 # BA fixed, export auto-detected
#   bash onboard-wrapper.sh BILLING_ACCOUNT_ID EXPORT_PROJECT DETAILED_USAGE_DATASET PRICING_DATASET
#
# With 0 or 1 args, init.sh auto-selects the single visible BA and/or scans the
# BA's projects for the export tables. Pass all 4 to pin them explicitly.

set -euo pipefail

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_blu='\033[0;34m'; c_off='\033[0m'
log() { printf "%b %s\n" "${c_blu}▸${c_off}" "$*" >&2; }
ok()  { printf "%b %s\n" "${c_grn}✅${c_off}" "$*" >&2; }
die() { printf "%b %s\n" "${c_red}✗${c_off}"  "$*" >&2; exit 1; }

# ── Arg parsing ──────────────────────────────────────────────────
# 0 args = full auto-detect, 1 = BA only, 4 = fully explicit. 2/3 are ambiguous.
case $# in
  0|1|4) ;;
  *) die "Pass 0 args (auto-detect), 1 (BILLING_ACCOUNT_ID), or 4 (BA EXPORT_PROJECT DETAILED_USAGE_DATASET PRICING_DATASET)" ;;
esac

BILLING_ACCOUNT_ID="${1:-}"
EXPORT_PROJECT_ID="${2:-}"
DETAILED_USAGE_DATASET="${3:-}"
PRICING_DATASET="${4:-}"

# ── Path to the underlying onboard script ────────────────────────
# In Cloud Shell, this repo is cloned to ~/cloudshell_open by default;
# adjust if your tutorial set cloudshell_workspace differently.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD="${SCRIPT_DIR}/init.sh"

[[ -x "${ONBOARD}" ]] || die "Could not find ${ONBOARD} (or not executable). Make sure you cloned the full repo."

# ── Friendly summary ─────────────────────────────────────────────
echo ""
log "About to onboard your GCP billing data to LumiTure:"
echo "    Billing Account:        ${BILLING_ACCOUNT_ID:-<auto-select single BA>}"
echo "    Export Project:         ${EXPORT_PROJECT_ID:-<auto-detect>}"
echo "    Detailed Usage dataset: ${DETAILED_USAGE_DATASET:-<auto-detect>}"
echo "    Pricing dataset:        ${PRICING_DATASET:-<auto-detect>}"
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

# Forward only the values provided; init.sh auto-detects the rest.
ARGS=()
[[ -n "${BILLING_ACCOUNT_ID}" ]]   && ARGS+=(--billing-account-id "${BILLING_ACCOUNT_ID}")
[[ -n "${EXPORT_PROJECT_ID}" ]]    && ARGS+=(--export-project "${EXPORT_PROJECT_ID}")
[[ -n "${DETAILED_USAGE_DATASET}" ]] && ARGS+=(--detailed-usage-dataset "${DETAILED_USAGE_DATASET}")
[[ -n "${PRICING_DATASET}" ]]      && ARGS+=(--pricing-dataset "${PRICING_DATASET}")

"${ONBOARD}" "${ARGS[@]}"

echo ""
ok "Done. Copy the JSON values above into the LumiTure wizard:"
echo "    👉 https://app.lumiture.ai/authorization/billing-integration/gcp"
echo ""
echo "After you submit, the status will flip to CONNECTED within ~15s,"
echo "and your dashboard will start populating in 5-15 minutes."
