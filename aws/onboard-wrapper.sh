#!/usr/bin/env bash
# LumiTure AWS Onboarding — CloudShell wrapper
#
# Thin wrapper around init.sh for AWS CloudShell.
#
# Usage:
#   bash onboard-wrapper.sh [EXTERNAL_ID] [ROLE_NAME] [POLICY_NAME]
#
# All positionals are optional:
#   EXTERNAL_ID   the ExternalId shown in the LumiTure wizard. When omitted,
#                 init.sh reuses the one on an existing role, fetches one via
#                 your session token, or generates one.
#   ROLE_NAME     defaults to LumiTureIntegrationRole
#   POLICY_NAME   defaults to LumiTureIntegrationPolicy
#
# Env vars — the wizard sets LUMITURE_JWT for a one-paste, no-typing flow:
#   LUMITURE_JWT   your LumiTure session token. When set, onboarding runs the
#                  permission check and registers the integration directly —
#                  no manual form entry. When absent, the script prints the
#                  form values for you to paste into the wizard.
#   LUMITURE_API   API base override (default https://api.lumiture.ai)
#   WITH_USAGE=1   ALSO deploy the member-account monitoring StackSet
#                  (default: skipped — it touches every member account and
#                  enables org-wide StackSets trusted access)

set -euo pipefail

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()  { printf "%b %s\n" "${c_blu}▸${c_off}" "$*" >&2; }
ok()   { printf "%b %s\n" "${c_grn}✅${c_off}" "$*" >&2; }
warn() { printf "%b %s\n" "${c_ylw}⚠${c_off}"  "$*" >&2; }
die()  { printf "%b %s\n" "${c_red}✗${c_off}"  "$*" >&2; exit 1; }

# ── Arg parsing ──────────────────────────────────────────────────
# 0 args = all defaults, 1 = ExternalId only, 3 = fully explicit. 2 is ambiguous.
case $# in
  0|1|3) ;;
  *) die "Pass 0 args (all defaults), 1 (EXTERNAL_ID), or 3 (EXTERNAL_ID ROLE_NAME POLICY_NAME)" ;;
esac

EXTERNAL_ID="${1:-}"
ROLE_NAME="${2:-}"
POLICY_NAME="${3:-}"

# ── Locate the underlying onboard script ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONBOARD="${SCRIPT_DIR}/init.sh"
[[ -x "${ONBOARD}" ]] || die "Could not find ${ONBOARD} (or not executable). Make sure you cloned the full repo."

# ── Auto-flow inputs (env) ───────────────────────────────────────
LUMITURE_JWT="${LUMITURE_JWT:-}"
LUMITURE_API="${LUMITURE_API:-}"

# ── Summary ──────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
echo ""
log "About to onboard your AWS billing data to LumiTure:"
echo "    Account:  ${ACCOUNT_ID:-<not logged in?>}"
echo "    Role:     ${ROLE_NAME:-LumiTureIntegrationRole}"
echo "    Policy:   ${POLICY_NAME:-LumiTureIntegrationPolicy}"
echo ""
log "This will:"
echo "    1. Confirm this is the Organization management (payer) account + check export quota"
echo "    2. Create the LumiTure IAM policy (billing-export management, writes limited to"
echo "       the two dedicated lumiture-* buckets) and the cross-account role (+ ExternalId)"
STEP=3
if [[ "${WITH_USAGE:-0}" == "1" ]]; then
  echo "    ${STEP}. Deploy the member-account monitoring StackSet (WITH_USAGE=1)"
  STEP=4
fi
if [[ -n "${LUMITURE_JWT}" ]]; then
  echo "    ${STEP}. Register the integration with LumiTure automatically (no manual form entry)"
else
  echo "    ${STEP}. Print form values for you to paste into the LumiTure wizard"
fi
echo ""
[[ -t 0 ]] || die "Interactive confirmation needs a terminal; run init.sh directly for non-interactive use."
read -r -p "Continue? [Y/n] " confirm || die "Could not read confirmation."
[[ "${confirm:-Y}" =~ ^[Yy] ]] || die "Aborted."

echo ""
log "Running onboarding..."
echo ""

# ── Build args + run ─────────────────────────────────────────────
ARGS=()
[[ -n "${EXTERNAL_ID}" ]] && ARGS+=( --external-id "${EXTERNAL_ID}" )
[[ -n "${ROLE_NAME}" ]]   && ARGS+=( --role-name "${ROLE_NAME}" )
[[ -n "${POLICY_NAME}" ]] && ARGS+=( --policy-name "${POLICY_NAME}" )
[[ -n "${LUMITURE_API}" ]] && ARGS+=( --lumiture-api "${LUMITURE_API}" )
[[ -n "${LUMITURE_JWT}" ]] && ARGS+=( --lumiture-jwt "${LUMITURE_JWT}" )
# Usage StackSet is opt-in (org-wide footprint); env opt-in.
[[ "${WITH_USAGE:-0}" == "1" ]] && ARGS+=( --with-usage )

# Guard the empty-array case — "${ARGS[@]}" under `set -u` is an unbound-variable
# error on bash < 4.4 (e.g. macOS's stock 3.2), which is the 0-arg default path.
if [[ ${#ARGS[@]} -gt 0 ]]; then
  "${ONBOARD}" "${ARGS[@]}"
else
  "${ONBOARD}"
fi

echo ""
if [[ -n "${LUMITURE_JWT}" ]]; then
  ok "Done — your account is registered with LumiTure."
  echo "LumiTure has provisioned the billing exports; cost data appears after the first"
  echo "daily export run lands (~24h, with the current billing month to date; no prior-month history)."
else
  ok "Role + policy done. Enter the JSON values above into the LumiTure wizard:"
  echo "    👉 https://app.lumiture.ai/authorization/billing-integration/aws"
  if [[ "${WITH_USAGE:-0}" == "1" ]]; then
    echo "    👉 usage (after billing connects): https://app.lumiture.ai/authorization/usage-integration/aws"
  fi
fi
