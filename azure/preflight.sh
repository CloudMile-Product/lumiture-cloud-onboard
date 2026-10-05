#!/usr/bin/env bash
# LumiTure Azure pre-session check — READ-ONLY, makes no cloud changes.
#
# Run in Azure Cloud Shell (Bash) as the SAME person who will drive the onboarding
# session. READY means none of the consent or permission prerequisites it checks
# is missing, and anything it cannot verify counts as NOT READY, so a missing role
# is found days before the session instead of halfway through it.
#
# Checked at subscription scope from your role assignments. Not evaluated: deny
# assignments, grants that exist only on a resource group or resource, and Azure
# Policy (e.g. allowed locations, no public storage) that can block init.sh's writes.
#
# If your role comes from PIM (Privileged Identity Management), ACTIVATE it first —
# an eligible-but-inactive role does not count, here or on the day.
#
# Usage:
#   bash preflight.sh <SUBSCRIPTION_ID> [<SUBSCRIPTION_ID> ...] [--no-usage]
#
#   --no-usage   billing only; don't require the custom-role permission for usage / rightsizing
#
# Exit code: 0 = all required checks passed, 1 = at least one FAIL.

set -uo pipefail

readonly LUMITURE_APP_ID="c871cf6f-dd8d-487a-a908-a66245655b0e"
readonly ARM="https://management.azure.com"

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
FAILS=0; WARNS=0; SUMMARY=""
pass() { printf "  %b %s\n" "${c_grn}PASS${c_off}" "$*"; }
fail() { printf "  %b %s\n" "${c_red}FAIL${c_off}" "$*"; FAILS=$((FAILS+1)); SUMMARY="${SUMMARY}FAIL  ${CUR}: $*\n"; }
warn() { printf "  %b %s\n" "${c_ylw}WARN${c_off}" "$*"; WARNS=$((WARNS+1)); SUMMARY="${SUMMARY}WARN  ${CUR}: $*\n"; }
info() { printf "  %b %s\n" "${c_blu}info${c_off}" "$*"; }
hdr()  { printf "\n%b\n" "${c_blu}== $* ==${c_off}"; }

SUBS=(); WITH_USAGE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-usage) WITH_USAGE=0; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) SUBS+=("$1"); shift ;;
  esac
done
[[ ${#SUBS[@]} -gt 0 ]] || { sed -n '2,21p' "$0"; exit 2; }
for t in az jq; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

ACCT=$(az account show -o json 2>/dev/null) || { echo "No active az login — run 'az login' first (or 'az login --allow-no-subscriptions' if this account has no subscriptions yet)" >&2; exit 2; }
ME=$(jq -r '.user.name' <<<"${ACCT}")
TENANT=$(jq -r '.tenantId' <<<"${ACCT}")

CUR="tenant"
hdr "Login / tenant ${TENANT}"
info "Checking as: ${ME}"
info "This must be the person who will run the onboarding on the day."

# Admin consent: either LumiTure's SP is already in the tenant, or this login can consent.
if sperr=$(az ad sp show --id "${LUMITURE_APP_ID}" --query id -o tsv 2>&1 >/dev/null); then
  pass "LumiTure app is already consented in this tenant"
elif ! grep -qiE "does not exist|doesn't exist|not found" <<<"${sperr}"; then
  fail "could not check whether LumiTure is consented (cannot read the directory: $(grep -v '^WARNING' <<<"${sperr}" | head -1 | cut -c1-160)) — have a directory admin confirm, then re-run"
else
  # Transitive, so a role held through a role-assignable group counts.
  roles=$(az rest --method get \
    --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName' \
    --query 'value[].displayName' -o tsv 2>/dev/null)
  if grep -qxE "Global Administrator|Privileged Role Administrator" <<<"${roles}"; then
    fail "LumiTure app not consented yet — init.sh stops until it is. Your role ($(grep -xE 'Global Administrator|Privileged Role Administrator' <<<"${roles}" | head -1)) can consent: click 'Connect Azure' in the LumiTure wizard and Accept, then re-run this check"
  else
    fail "LumiTure app not consented yet — init.sh stops until it is. Ask a Global Administrator to click 'Connect Azure' in the LumiTure wizard and Accept, then re-run this check"
  fi
fi

# Effective permission check against the caller's own role assignments
# (union of each assignment's actions minus its notActions; wildcards honoured).
JQ_ALLOWED='
  def re: "^" + (gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*")) + "$";
  def m($a): . as $p | $a | test($p|re; "i");
  . as $perms | $want | map(. as $w | {(.): ([$perms.value[] | select((any(.actions[]; m($w))) and (any((.notActions // [])[]; m($w)) | not))] | length > 0)}) | add
'

# Role-assignment rights that come only from a CONDITIONAL assignment (delegation limited to
# certain roles or principals) can't be evaluated here, so they must not count as READY.
# The permissions API omits conditions, so read the caller's role assignments directly.
check_unconditional_delegation() {
  local sub="$1" me_id asg='[]' page pages=0 url defs='[]' rid def skipped=0
  if ! me_id=$(az ad signed-in-user show --query id -o tsv 2>/dev/null) || [[ -z "${me_id}" ]]; then
    fail "could not read your user ID to check your role assignments — ask LumiTure to verify by hand"
    return
  fi
  url="${ARM}/subscriptions/${sub}/providers/Microsoft.Authorization/roleAssignments?\$filter=assignedTo('${me_id}')&api-version=2022-04-01"
  while [[ -n "${url}" && ${pages} -lt 20 ]]; do
    pages=$((pages+1))
    if ! page=$(az rest --method get -o json --url "${url}" 2>/dev/null); then
      fail "could not read your role assignments to confirm your role-assignment rights are unconditional — ask LumiTure to verify by hand"
      return
    fi
    asg=$(jq -c --argjson p "${page}" '. + ($p.value // [])' <<<"${asg}")
    url=$(jq -r '.nextLink // empty' <<<"${page}")
  done
  if [[ -n "${url}" ]]; then
    fail "your role-assignment list has more than 20 pages; the check is incomplete — ask LumiTure to verify by hand"
    return
  fi
  # Only assignments that apply at the subscription: its own scope, a management group, or root.
  asg=$(jq -c --arg sub "/subscriptions/${sub}" '{value: [.[] | select((.properties.scope | ascii_downcase) as $s
        | $s == ($sub | ascii_downcase) or $s == "/" or ($s | startswith("/providers/microsoft.management/")))]}' <<<"${asg}")
  # Each assignment's role-definition permissions, tagged conditional or not.
  for rid in $(jq -r '[.value[].properties.roleDefinitionId] | unique | .[]' <<<"${asg}"); do
    if ! def=$(az rest --method get -o json --url "${ARM}${rid}?api-version=2022-04-01" 2>/dev/null); then
      skipped=$((skipped+1)); continue
    fi
    defs=$(jq -c --arg id "${rid}" --argjson d "${def}" '. + [{id: $id, permissions: ($d.properties.permissions // [])}]' <<<"${defs}")
  done
  local uncond cond want='["Microsoft.Authorization/roleAssignments/write"]' conds
  uncond=$(jq -c --argjson defs "${defs}" '{value: [.value[] | select(.properties.condition == null) | .properties.roleDefinitionId as $r | ($defs[] | select(.id == $r) | .permissions[])]}' <<<"${asg}")
  cond=$(jq -c --argjson defs "${defs}" '{value: [.value[] | select(.properties.condition != null) | .properties.roleDefinitionId as $r | ($defs[] | select(.id == $r) | .permissions[])]}' <<<"${asg}")
  grants() { jq --argjson want "${want}" "${JQ_ALLOWED}" <<<"$1" | jq -r '.[]'; }
  if [[ "$(grants "${uncond}")" == "true" ]]; then
    pass "can assign roles to LumiTure (roleAssignments/write, unconditional)"
  elif [[ "$(grants "${cond}")" == "true" ]]; then
    fail "your right to assign roles comes from a conditional assignment, which this check can't evaluate. init.sh assigns Cost Management Reader, Storage Blob Data Reader, Storage Blob Data Contributor and a custom role — none of them privileged admin roles. If your condition is the portal's 'allow assigning all roles except privileged administrator roles' option, init.sh will work: send this output to LumiTure to confirm (condition below)"
    conds=$(jq -r '[.value[] | select(.properties.condition != null) | .properties.condition] | unique | .[]' <<<"${asg}")
    while IFS= read -r c; do [[ -n "${c}" ]] && info "condition: $(tr -s ' \n' ' ' <<<"${c}" | cut -c1-400)"; done <<<"${conds}"
  elif [[ ${skipped} -gt 0 ]]; then
    fail "could not read ${skipped} of your role definition(s), so your role-assignment rights can't be confirmed — ask LumiTure to verify by hand"
  else
    fail "none of your role assignments at this subscription (or above) grants role-assignment rights, although the permissions list does — ask LumiTure to verify by hand"
  fi
}

check_sub() {
  local sub="$1"
  CUR="sub ${sub}"
  hdr "Subscription ${sub}"

  local s
  if ! s=$(az rest --method get --url "${ARM}/subscriptions/${sub}?api-version=2022-12-01" -o json 2>/dev/null); then
    fail "subscription not visible to this login (wrong ID, wrong tenant, or no role on it)"
    return
  fi
  local stenant quota
  stenant=$(jq -r '.tenantId // empty' <<<"${s}")
  quota=$(jq -r '.subscriptionPolicies.quotaId' <<<"${s}")
  info "name: $(jq -r '.displayName' <<<"${s}") · state: $(jq -r '.state' <<<"${s}") · offer: ${quota}"
  local state
  state=$(jq -r '.state' <<<"${s}")
  case "${state}" in
    Enabled) ;;
    Warned|PastDue) warn "subscription is ${state} (billing issue) — it still accepts changes, but settle it before the session" ;;
    *) fail "subscription is ${state} — init.sh's writes will fail; re-enable it first"; return ;;
  esac
  if [[ -n "${stenant}" && "${stenant}" != "${TENANT}" ]]; then
    fail "subscription is in tenant ${stenant}, but you are signed in to ${TENANT} — run: az login --tenant ${stenant}"
    return
  fi
  [[ "${quota}" == CSP_* ]] && info "CSP subscription — bought through a Microsoft partner (reseller)"

  local perms='[]' page pages=0 url="${ARM}/subscriptions/${sub}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
  while [[ -n "${url}" && ${pages} -lt 20 ]]; do
    pages=$((pages+1))
    if ! page=$(az rest --method get --url "${url}" -o json 2>/dev/null); then
      fail "could not read your effective permissions on this subscription"
      return
    fi
    perms=$(jq -c --argjson p "${page}" '. + ($p.value // [])' <<<"${perms}")
    url=$(jq -r '.nextLink // empty' <<<"${page}")
  done
  if [[ -n "${url}" ]]; then
    fail "your permission list on this subscription has more than 20 pages; the check is incomplete — ask LumiTure to verify by hand"
    return
  fi
  perms=$(jq -c '{value: .}' <<<"${perms}")

  local want='["Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/blobServices/containers/write",
    "Microsoft.Storage/storageAccounts/managementPolicies/write",
    "Microsoft.CostManagement/exports/write",
    "Microsoft.EventGrid/eventSubscriptions/write",
    "Microsoft.Authorization/roleDefinitions/write",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.CostManagement/exports/read",
    "Microsoft.EventGrid/eventSubscriptions/read",
    "Microsoft.CostManagementExports/register/action",
    "Microsoft.EventGrid/register/action"]'
  local res
  res=$(jq --argjson want "${want}" "${JQ_ALLOWED}" <<<"${perms}")
  ok_action() { [[ "$(jq -r --arg a "$1" '.[$a]' <<<"${res}")" == "true" ]]; }

  if ok_action Microsoft.Authorization/roleAssignments/write; then
    check_unconditional_delegation "${sub}"
  else
    fail "cannot assign roles — needs Owner, or User Access Administrator + Contributor, on the subscription"
  fi

  local a missing=""
  for a in Microsoft.Resources/subscriptions/resourceGroups/write \
           Microsoft.Storage/storageAccounts/write \
           Microsoft.Storage/storageAccounts/blobServices/containers/write \
           Microsoft.CostManagement/exports/write \
           Microsoft.EventGrid/eventSubscriptions/write \
           Microsoft.Authorization/roleAssignments/read \
           Microsoft.Authorization/roleDefinitions/read \
           Microsoft.Storage/storageAccounts/read \
           Microsoft.CostManagement/exports/read \
           Microsoft.EventGrid/eventSubscriptions/read; do
    ok_action "$a" || missing="${missing} ${a}"
  done
  [[ -z "${missing}" ]] \
    && pass "can create and verify the export storage, Cost Management exports and Event Grid subscription" \
    || fail "missing:${missing} — needs Contributor (or Owner) on the subscription"
  # init.sh treats a failed lifecycle rule as non-fatal, so this only warns.
  ok_action Microsoft.Storage/storageAccounts/managementPolicies/write \
    || warn "cannot set the export blob lifecycle rule (managementPolicies/write) — init.sh continues without it; use --no-retention to skip it"

  if [[ ${WITH_USAGE} -eq 1 ]]; then
    ok_action Microsoft.Authorization/roleDefinitions/write \
      && pass "can create the LumiTure usage custom role (rightsizing)" \
      || fail "cannot create the usage custom role (roleDefinitions/write) — needs Owner or User Access Administrator; or onboard with --no-usage"
  fi

  # init.sh always runs 'az provider register', even when the provider is already registered.
  local ns state
  for ns in Microsoft.CostManagementExports Microsoft.EventGrid; do
    state=$(az provider show -n "${ns}" --subscription "${sub}" --query registrationState -o tsv 2>/dev/null)
    if ok_action "${ns}/register/action"; then
      pass "can register resource provider ${ns} (currently ${state:-unknown}; init.sh always registers it)"
    else
      fail "cannot register resource provider ${ns} (currently ${state:-unknown}) — init.sh always runs the register step; needs Contributor or Owner"
    fi
  done

  # Diagnostic only (init.sh never queries cost): can this login read cost at all?
  local q qerr i
  qerr=$(mktemp)
  for i in 1 2; do
    # stdout only: az may print WARNING lines on stderr that are not part of the JSON.
    q=$(az rest --method post \
        --url "${ARM}/subscriptions/${sub}/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
        --body '{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"c":{"name":"Cost","function":"Sum"}}}}' \
        -o json 2>"${qerr}")
    jq -e '.properties.rows' >/dev/null 2>&1 <<<"${q}" && break
    [[ ${i} -eq 1 ]] && sleep 5
  done
  if jq -e '.properties.rows' >/dev/null 2>&1 <<<"${q}"; then
    pass "can read Cost Management data"
  else
    local why
    why=$(grep -v '^WARNING' "${qerr}" | tr '\n' ' ' | cut -c1-200)
    if grep -q 'Too Many Requests\|"429"' <<<"${why}"; then
      info "Cost Management throttled this check (HTTP 429) — a rate limit, not a permission problem; re-run later if you want this diagnostic"
    elif [[ "${quota}" == CSP_* ]]; then
      warn "cannot read Cost Management data (${why:-no error text}) — on a CSP subscription the partner may need to enable cost visibility for the customer in Partner Center"
    else
      warn "cannot read Cost Management data (${why:-no error text})"
    fi
  fi
  rm -f "${qerr}"
}

for sub in "${SUBS[@]}"; do check_sub "${sub}"; done

hdr "Summary for ${ME}"
if [[ -n "${SUMMARY}" ]]; then printf "%b" "${SUMMARY}"; fi
if [[ ${FAILS} -eq 0 ]]; then
  printf "%b\n" "${c_grn}READY${c_off} — ${#SUBS[@]} subscription(s), ${WARNS} warning(s). Send this output to LumiTure."
  exit 0
fi
printf "%b\n" "${c_red}NOT READY${c_off} — ${FAILS} failure(s), ${WARNS} warning(s). Fix the FAIL lines (or bring the person who can) before the session."
exit 1
