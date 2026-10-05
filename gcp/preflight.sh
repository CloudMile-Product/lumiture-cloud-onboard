#!/usr/bin/env bash
# LumiTure GCP pre-session check — READ-ONLY, changes nothing.
#
# Run in Google Cloud Shell as the SAME person who will drive the onboarding
# session. It asserts that this login holds every permission gcp/init.sh needs,
# per billing account, so a missing grant is found days before the session
# instead of halfway through it.
#
# Usage:
#   bash preflight.sh <BA_ID> [<BA_ID> ...] [--export-project <id>] [--scoping-project <id>]
#
#   --export-project   skip the auto-scan and check this project as the billing-export project
#   --scoping-project  project LumiTure reads usage metrics from (default: the export project)
#
# Exit code: 0 = all required checks passed, 1 = at least one FAIL.

set -uo pipefail

readonly LUMITURE_SA="lumiture-client@tw-rd-app-finops-prod.iam.gserviceaccount.com"

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
FAILS=0; WARNS=0; SUMMARY=""
pass() { printf "  %b %s\n" "${c_grn}PASS${c_off}" "$*"; }
fail() { printf "  %b %s\n" "${c_red}FAIL${c_off}" "$*"; FAILS=$((FAILS+1)); SUMMARY="${SUMMARY}FAIL  ${CUR}: $*\n"; }
warn() { printf "  %b %s\n" "${c_ylw}WARN${c_off}" "$*"; WARNS=$((WARNS+1)); SUMMARY="${SUMMARY}WARN  ${CUR}: $*\n"; }
info() { printf "  %b %s\n" "${c_blu}info${c_off}" "$*"; }
hdr()  { printf "\n%b\n" "${c_blu}== $* ==${c_off}"; }

BAS=(); EXPORT_PROJECT_ARG=""; SCOPING_PROJECT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-project) EXPORT_PROJECT_ARG="$2"; shift 2 ;;
    --scoping-project) SCOPING_PROJECT_ARG="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) BAS+=("$1"); shift ;;
  esac
done
[[ ${#BAS[@]} -gt 0 ]] || { sed -n '2,17p' "$0"; exit 2; }

for t in gcloud bq jq curl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

ME=$(gcloud config get-value account 2>/dev/null)
TOK=$(gcloud auth print-access-token 2>/dev/null)
[[ -n "${ME}" && -n "${TOK}" ]] || { echo "No active gcloud login — run 'gcloud auth login' first" >&2; exit 2; }
CUR="login"
hdr "Login"
info "Checking as: ${ME}"
info "This must be the person who will run the onboarding on the day."

# POST <url> testIamPermissions with the given permissions; prints the granted ones.
test_perms() {
  local url="$1"; shift
  local body
  body=$(jq -cn '{permissions: $ARGS.positional}' --args "$@")
  curl -s -X POST "${url}" -H "Authorization: Bearer ${TOK}" \
    -H "Content-Type: application/json" -d "${body}" | jq -r '.permissions[]?'
}
has() { grep -qx "$1" <<<"$2"; }

# bq ls as JSON. Empty project or BigQuery API off → empty list; any other error → return 1.
UNREAD_F=$(mktemp); trap 'rm -f "${UNREAD_F}"' EXIT
bq_ls_json() {
  local out
  out=$(bq ls --format=json --max_results=1000 "$@" 2>/dev/null)
  case "${out}" in
    \[*|\{*) printf '%s' "${out}" ;;
    ""|*"has not enabled BigQuery"*) printf '[]' ;;
    *) echo x >>"${UNREAD_F}"; printf '[]'; return 1 ;;
  esac
}
datasets_of() { bq_ls_json --project_id="$1" | jq -r '.[]?.datasetReference.datasetId'; }
tables_of()   { bq_ls_json "$1:$2" | jq -r '.[]?.tableReference.tableId'; }

check_ba() {
  local ba="$1"
  CUR="BA ${ba}"
  hdr "Billing account ${ba}"

  local desc
  if ! desc=$(gcloud billing accounts describe "${ba}" --format=json 2>&1); then
    fail "cannot read the billing account (no billing.accounts.get, or wrong ID): $(head -1 <<<"${desc}")"
    return
  fi
  info "name: $(jq -r '.displayName' <<<"${desc}") · open: $(jq -r '.open' <<<"${desc}")"
  local parent
  parent=$(jq -r '.masterBillingAccount // empty' <<<"${desc}")
  if [[ -n "${parent}" ]]; then
    info "RESELLER SUB-ACCOUNT — parent ${parent#billingAccounts/}. The reseller may hold the admin role, not you."
  else
    info "direct billing account (no reseller parent)"
  fi

  local granted
  granted=$(test_perms "https://cloudbilling.googleapis.com/v1/billingAccounts/${ba}:testIamPermissions" \
    billing.accounts.get billing.accounts.getIamPolicy billing.accounts.setIamPolicy billing.resourceAssociations.list)

  # Granting roles/billing.viewer to LumiTure's SA needs setIamPolicy (roles/billing.admin).
  if has billing.accounts.setIamPolicy "${granted}"; then
    pass "can grant roles/billing.viewer to LumiTure (billing.accounts.setIamPolicy)"
  else
    local already=""
    if has billing.accounts.getIamPolicy "${granted}"; then
      already=$(gcloud billing accounts get-iam-policy "${ba}" --format=json 2>/dev/null \
        | jq -r --arg m "serviceAccount:${LUMITURE_SA}" '.bindings[]? | select(.role=="roles/billing.viewer") | .members[] | select(.==$m)')
    fi
    if [[ -n "${already}" ]]; then
      pass "LumiTure SA already holds roles/billing.viewer — no grant needed on the day"
    elif [[ -n "${parent}" ]]; then
      fail "cannot grant roles/billing.viewer (needs Billing Account Administrator). Ask the reseller that owns ${parent#billingAccounts/} to grant roles/billing.viewer on ${ba} to ${LUMITURE_SA}"
    else
      fail "cannot grant roles/billing.viewer (needs Billing Account Administrator on ${ba})"
    fi
  fi
  has billing.resourceAssociations.list "${granted}" \
    && pass "can list projects linked to the BA (needed for export auto-detect)" \
    || warn "cannot list projects under the BA — pass --export-project explicitly on the day"

  # Locate the Detailed Usage Cost export by its table name.
  local table="gcp_billing_export_resource_v1_${ba//-/_}" proj="" ds="" p d
  : >"${UNREAD_F}"
  if [[ -n "${EXPORT_PROJECT_ARG}" ]]; then
    proj="${EXPORT_PROJECT_ARG}"
    for d in $(datasets_of "${proj}"); do
      tables_of "${proj}" "${d}" | grep -qx "${table}" && { ds="$d"; break; }
    done
  else
    info "scanning the BA's projects for ${table} …"
    for p in $(gcloud billing projects list --billing-account="${ba}" --format='value(projectId)' 2>/dev/null); do
      for d in $(datasets_of "${p}"); do
        if tables_of "${p}" "${d}" | grep -qx "${table}"; then
          proj="$p"; ds="$d"; break 2
        fi
      done
    done
  fi
  if [[ -z "${ds}" ]]; then
    local unreadable
    unreadable=$(wc -l <"${UNREAD_F}" | tr -d ' ')
    if [[ ${unreadable} -gt 0 ]]; then
      fail "Detailed Usage Cost export (${table}) not found in the projects you can read; ${unreadable} project/dataset listing(s) were denied. Re-run with --export-project <id>, or enable the export ≥ 24-48 h before the session"
    else
      fail "Detailed Usage Cost export not found (${table}). Enable it in Billing → Billing export → BigQuery export ≥ 24-48 h before the session"
    fi
    return
  fi
  local meta
  meta=$(bq show --format=json "${proj}:${ds}.${table}" 2>/dev/null)
  pass "Detailed Usage Cost export → ${proj}:${ds} (rows ${meta:+$(jq -r '.numRows' <<<"${meta}")}, last modified $(jq -r '(.lastModifiedTime|tonumber/1000|todate)' <<<"${meta}" 2>/dev/null))"

  local pds=""
  for d in $(datasets_of "${proj}"); do
    tables_of "${proj}" "${d}" | grep -qx cloud_pricing_export && { pds="$d"; break; }
  done
  if [[ -n "${pds}" ]]; then
    pass "Pricing export → ${proj}:${pds}"
  else
    local cfg disabled
    cfg=$(bq ls --transfer_config --transfer_location=us --project_id="${proj}" --format=json 2>/dev/null \
      | jq -r '.[]? | select(.displayName | test("Pricing"; "i")) | .name' | head -1)
    if [[ -n "${cfg}" ]]; then
      disabled=$(bq show --format=json --transfer_config "${cfg}" 2>/dev/null | jq -r '.disabled // false')
      [[ "${disabled}" == "true" ]] \
        && fail "Pricing export is configured but its transfer is DISABLED — re-save it in Billing → Billing export → Pricing and complete the authorization prompt" \
        || warn "Pricing transfer is enabled but no cloud_pricing_export table yet — first load can take up to 48 h"
    else
      fail "Pricing export not enabled in ${proj} — enable it in Billing → Billing export → BigQuery export → Pricing"
    fi
  fi

  TABLE="${table}" check_export_project "${proj}" "${ds}" "${pds}"
  check_scoping_project "${SCOPING_PROJECT_ARG:-${proj}}"
}

check_export_project() {
  local proj="$1" ds="$2" pds="$3"
  local granted out
  granted=$(test_perms "https://cloudresourcemanager.googleapis.com/v1/projects/${proj}:testIamPermissions" \
    bigquery.datasets.update)

  # init.sh runs a freshness query in the export project; a dry run of the same query
  # (free) proves bigquery.jobs.create there plus read access to the table.
  if out=$(bq query --dry_run --use_legacy_sql=false --project_id="${proj}" \
        "SELECT export_time FROM \`${proj}.${ds}.${TABLE}\` LIMIT 1" 2>&1); then
    pass "can query the export in ${proj} (dry run of init.sh's freshness query)"
  else
    fail "cannot query the export in ${proj} — needs roles/bigquery.user on ${proj} + read on ${ds}: $(tr '\n' ' ' <<<"${out}" | sed 's/.*in query operation: //' | cut -c1-220)"
  fi

  # Granting READER on the datasets needs bigquery.datasets.update — project-level, or OWNER on the dataset itself.
  local d
  for d in ${ds} ${pds}; do
    if has bigquery.datasets.update "${granted}"; then
      pass "can grant LumiTure READER on ${proj}:${d}"
    elif bq show --format=json "${proj}:${d}" 2>/dev/null \
         | jq -e --arg me "${ME}" '[.access[]? | select(.role=="OWNER" and (.userByEmail // "" | ascii_downcase) == ($me|ascii_downcase))] | length > 0' >/dev/null; then
      pass "can grant LumiTure READER on ${proj}:${d} (you are dataset OWNER)"
    else
      fail "cannot grant LumiTure READER on ${proj}:${d} — needs roles/bigquery.dataOwner (or bigquery.admin) on the dataset or project"
    fi
  done
}

check_scoping_project() {
  local proj="$1"
  local granted
  granted=$(test_perms "https://cloudresourcemanager.googleapis.com/v1/projects/${proj}:testIamPermissions" \
    resourcemanager.projects.setIamPolicy)
  has resourcemanager.projects.setIamPolicy "${granted}" \
    && pass "can grant roles/monitoring.viewer on scoping project ${proj} (usage / rightsizing)" \
    || warn "cannot grant roles/monitoring.viewer on ${proj} (usage / rightsizing) — needs Project IAM Admin or Owner; billing still works without it"
}

for ba in "${BAS[@]}"; do check_ba "${ba}"; done

hdr "Summary for ${ME}"
if [[ -n "${SUMMARY}" ]]; then printf "%b" "${SUMMARY}"; fi
if [[ ${FAILS} -eq 0 ]]; then
  printf "%b\n" "${c_grn}READY${c_off} — ${#BAS[@]} billing account(s), ${WARNS} warning(s). Send this output to LumiTure."
  exit 0
fi
printf "%b\n" "${c_red}NOT READY${c_off} — ${FAILS} failure(s), ${WARNS} warning(s). Fix the FAIL lines (or bring the person who can) before the session."
exit 1
