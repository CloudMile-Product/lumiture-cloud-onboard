#!/usr/bin/env bash
# LumiTure Azure Onboarding — Cloud Shell wrapper
#
# Thin wrapper around lumiture-azure-onboard.sh for Azure Cloud Shell.
#
# Usage:
#   bash onboard-wrapper.sh [SUBSCRIPTION_ID] [STORAGE_ACCOUNT] [STORAGE_RG] [LUMITURE_APP_ID]
#
# All positionals are optional:
#   SUBSCRIPTION_ID  auto-detected when you have exactly one enabled subscription
#   STORAGE_ACCOUNT  defaults to a deterministic per-subscription name
#   STORAGE_RG       defaults to lumiture-billing-rg
#   LUMITURE_APP_ID  defaults to the prod LumiTure SP (override for non-prod)
#
# Env vars — the wizard sets LUMITURE_JWT for a one-paste, no-typing flow:
#   LUMITURE_JWT   your LumiTure session token. When set, onboarding auto-fetches
#                  the billing event-trigger URL, wires the Event Grid subscription,
#                  and registers the connection directly — no manual form entry and
#                  no --event-trigger-url needed. When absent, the script prints the
#                  form values for you to paste into the wizard (and, without an
#                  event-trigger URL, warns that billing data won't flow yet).
#   LUMITURE_API   API base override (default https://api.lumiture.ai)
#   WITH_USAGE=1   also grant the usage/rightsizing role
#   WITH_FOCUS=1   also create a FOCUS-format export

set -euo pipefail

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()  { printf "%b %s\n" "${c_blu}▸${c_off}" "$*" >&2; }
ok()   { printf "%b %s\n" "${c_grn}✅${c_off}" "$*" >&2; }
warn() { printf "%b %s\n" "${c_ylw}⚠${c_off}"  "$*" >&2; }
die()  { printf "%b %s\n" "${c_red}✗${c_off}"  "$*" >&2; exit 1; }

# ── Positional args (all optional) ───────────────────────────────
SUBSCRIPTION_ID="${1:-}"
STORAGE_ACCOUNT="${2:-}"
STORAGE_RG="${3:-}"
LUMITURE_APP_ID="${4:-}"

# ── Locate the underlying onboard script ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD="${SCRIPT_DIR}/lumiture-azure-onboard.sh"
[[ -x "${ONBOARD}" ]] || die "Could not find ${ONBOARD} (or not executable). Make sure you cloned the full repo."

# ── Auto-detect the subscription when not given ──────────────────
if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  mapfile -t _subs < <(az account list --query "[?state=='Enabled'].id" -o tsv 2>/dev/null)
  if [[ "${#_subs[@]}" -eq 1 ]]; then
    SUBSCRIPTION_ID="${_subs[0]}"
    log "Auto-detected your subscription: ${SUBSCRIPTION_ID}"
  elif [[ "${#_subs[@]}" -eq 0 ]]; then
    die "No enabled subscriptions found for the logged-in account. Run 'az login' first."
  else
    warn "You have multiple subscriptions — pass the one to onboard as the first argument:"
    az account list --query "[?state=='Enabled'].{name:name, id:id}" -o table >&2
    die "e.g.  bash onboard-wrapper.sh <SUBSCRIPTION_ID>"
  fi
fi

# ── Defaults for storage (deterministic → idempotent across re-runs) ──
if [[ -z "${STORAGE_ACCOUNT}" ]]; then
  STORAGE_ACCOUNT="ltexp$(printf '%s' "${SUBSCRIPTION_ID}" | tr -d '-' | cut -c1-15)"
fi
STORAGE_RG="${STORAGE_RG:-lumiture-billing-rg}"

# ── Auto-flow inputs (env) ───────────────────────────────────────
LUMITURE_JWT="${LUMITURE_JWT:-}"
LUMITURE_API="${LUMITURE_API:-}"

# ── Summary ──────────────────────────────────────────────────────
echo ""
log "About to onboard your Azure billing data to LumiTure:"
echo "    Subscription:    ${SUBSCRIPTION_ID}"
echo "    Storage account: ${STORAGE_ACCOUNT}  (resource group ${STORAGE_RG})"
echo ""
log "This will:"
echo "    1. Verify LumiTure's service principal is consented in your tenant"
echo "    2. Ensure the storage account + container for the cost export exist"
echo "    3. Grant 'Cost Management Reader' (subscription) + 'Storage Blob Data Reader' (storage)"
echo "    4. Create a daily Cost Management export + wire the Event Grid subscription"
if [[ -n "${LUMITURE_JWT}" ]]; then
  echo "    5. Register the connection with LumiTure automatically (no manual form entry)"
else
  echo "    5. Print form values for you to paste into the LumiTure wizard"
  warn "No LUMITURE_JWT set → the Event Grid subscription can't be wired and billing"
  warn "  data won't flow. Launch this from the LumiTure wizard (which sets the token),"
  warn "  or export LUMITURE_JWT=<your session token> before re-running."
fi
echo ""
read -p "Continue? [Y/n] " confirm
[[ "${confirm:-Y}" =~ ^[Yy] ]] || die "Aborted."

echo ""
log "Running onboarding..."
echo ""

# ── Build args + run ─────────────────────────────────────────────
ARGS=( --subscription-id "${SUBSCRIPTION_ID}"
       --storage-account "${STORAGE_ACCOUNT}"
       --storage-rg "${STORAGE_RG}" )
[[ -n "${LUMITURE_APP_ID}" ]] && ARGS+=( --lumiture-app-id "${LUMITURE_APP_ID}" )
[[ -n "${LUMITURE_API}" ]]    && ARGS+=( --lumiture-api "${LUMITURE_API}" )
[[ -n "${LUMITURE_JWT}" ]]    && ARGS+=( --lumiture-jwt "${LUMITURE_JWT}" )
[[ "${WITH_USAGE:-0}" == "1" ]] && ARGS+=( --with-usage )
[[ "${WITH_FOCUS:-0}" == "1" ]] && ARGS+=( --with-focus )

"${ONBOARD}" "${ARGS[@]}"

echo ""
if [[ -n "${LUMITURE_JWT}" ]]; then
  ok "Done — your subscription is registered with LumiTure."
  echo "It flips to CONNECTED once the subscription sync runs; billing data appears after"
  echo "the export's first daily run lands (~24h) and is transferred to BigQuery."
else
  ok "Grants + export done. Enter the JSON values above into the LumiTure wizard:"
  echo "    👉 https://app.lumiture.ai/authorization/billing-data-integration/azure"
fi
