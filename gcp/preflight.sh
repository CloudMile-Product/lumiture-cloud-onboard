#!/usr/bin/env bash
# LumiTure GCP pre-session check — READ-ONLY, makes no cloud changes.
#
# Run in Google Cloud Shell as the SAME person who will drive the onboarding
# session. READY means none of the prerequisites it checks for init.sh (default
# dataset grant scope) is missing, and anything it cannot verify counts as NOT
# READY, so a missing grant is found days before the session instead of halfway
# through it.
#
# Usage:
#   bash preflight.sh <BA_ID> [<BA_ID> ...] [--export-project <id>] [--with-usage] [--scoping-project <id>]
#
#   --export-project   skip the auto-scan and check this project as the billing-export project
#   --with-usage       usage / rightsizing will be onboarded too (init.sh --with-usage): its grant becomes required
#   --scoping-project  project LumiTure reads usage metrics from (default: the export project)
#
# Exit code: 0 = all required checks passed, 1 = at least one FAIL.

set -uo pipefail
# Never let gcloud stop on an interactive prompt (e.g. "enable this API?"); take the default, No.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

readonly LUMITURE_SA="lumiture-client@tw-rd-app-finops-prod.iam.gserviceaccount.com"
# init.sh lists datasets without --max_results, so bq returns only the first 50.
readonly INIT_DATASET_LIMIT=50

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
FAILS=0; WARNS=0; SUMMARY=""
pass() { printf "  %b %s\n" "${c_grn}PASS${c_off}" "$*"; }
fail() { printf "  %b %s\n" "${c_red}FAIL${c_off}" "$*"; FAILS=$((FAILS+1)); SUMMARY="${SUMMARY}FAIL  ${CUR}: $*\n"; }
warn() { printf "  %b %s\n" "${c_ylw}WARN${c_off}" "$*"; WARNS=$((WARNS+1)); SUMMARY="${SUMMARY}WARN  ${CUR}: $*\n"; }
info() { printf "  %b %s\n" "${c_blu}info${c_off}" "$*"; }
hdr()  { printf "\n%b\n" "${c_blu}== $* ==${c_off}"; }
usage() { sed -n '2,17p' "$0"; exit "$1"; }

BAS=(); EXPORT_PROJECT_ARG=""; SCOPING_PROJECT_ARG=""; WITH_USAGE=0
need_val() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "Option $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-project) need_val "$@"; EXPORT_PROJECT_ARG="$2"; shift 2 ;;
    --scoping-project) need_val "$@"; SCOPING_PROJECT_ARG="$2"; shift 2 ;;
    --with-usage) WITH_USAGE=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) BAS+=("$1"); shift ;;
  esac
done
[[ ${#BAS[@]} -gt 0 ]] || usage 2

for t in gcloud bq jq curl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
# First bq run in a fresh shell prints a welcome banner on stdout; get it out of the way.
bq version </dev/null >/dev/null 2>&1

ME=$(gcloud config get-value account 2>/dev/null)
TOK=$(gcloud auth print-access-token 2>/dev/null)
[[ -n "${ME}" && -n "${TOK}" ]] || { echo "No active gcloud login — run 'gcloud auth login' first" >&2; exit 2; }
CUR="login"
hdr "Login"
info "Checking as: ${ME}"
info "This must be the person who will run the onboarding on the day."
# init.sh refuses to start without Application Default Credentials.
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  pass "Application Default Credentials available"
else
  fail "Application Default Credentials not set — run 'gcloud auth application-default login' (init.sh stops without them)"
fi

# POST <url> testIamPermissions with the given permissions; prints the granted ones.
# Returns 1 when the check itself failed (reason in NOTE_F, shown by the caller), so
# callers never report an API or network error as a missing permission.
test_perms() {
  local url="$1"; shift
  local body resp rc
  body=$(jq -cn '{permissions: $ARGS.positional}' --args "$@")
  # The token goes in via stdin, not argv, so it never shows in the process list.
  resp=$(printf 'Authorization: Bearer %s\n' "${TOK}" | curl -s --max-time 30 -X POST "${url}" \
    -H @- -H "Content-Type: application/json" -d "${body}")
  rc=$?
  if [[ ${rc} -ne 0 || -z "${resp}" ]]; then
    echo "no complete response, curl exit ${rc}" >"${NOTE_F}"
    return 1
  fi
  if ! jq -e 'type == "object" and (has("error") | not)' >/dev/null 2>&1 <<<"${resp}"; then
    local why
    why=$(jq -r '.error.message? // empty' 2>/dev/null <<<"${resp}" | cut -c1-200)
    echo "API error: ${why:-unexpected non-JSON response}" >"${NOTE_F}"
    return 1
  fi
  jq -r '.permissions[]?' <<<"${resp}"
}
has() { grep -qx "$1" <<<"$2"; }

# bq ls as JSON. Empty project or BigQuery API off → empty list; any other error → return 1.
UNREAD_F=$(mktemp); NOTE_F=$(mktemp); trap 'rm -f "${UNREAD_F}" "${NOTE_F}"' EXIT
# Drops anything bq prints before its JSON (banners, "WARNING: Could not setup log file").
json_only() { sed -n '/^[{[]/,$p'; }
bq_ls_json() {
  local raw out rc
  raw=$(bq ls --format=json --max_results=1000 "$@" </dev/null 2>/dev/null)
  rc=$?
  out=$(json_only <<<"${raw}")
  if [[ -n "${out}" ]]; then
    printf '%s' "${out}"
  elif [[ ( -z "${raw}" && ${rc} -eq 0 ) || "$(tr '\n' ' ' <<<"${raw}" | tr -s ' ')" == *"has not enabled BigQuery"* ]]; then
    printf '[]'
  else
    echo x >>"${UNREAD_F}"; printf '[]'; return 1
  fi
}
datasets_of() { bq_ls_json --project_id="$1" | jq -r '.[]?.datasetReference.datasetId'; }
tables_of()   { bq_ls_json "$1:$2" | jq -r '.[]?.tableReference.tableId'; }
rows_of()     { bq show --format=json "$1" 2>/dev/null | json_only | jq -r '.numRows // empty' 2>/dev/null; }

# Finds the dataset in <project> holding <table>; prints "<dataset> <0-based position>".
find_table() {
  local proj="$1" table="$2" i=0 d
  for d in $(datasets_of "${proj}"); do
    # grep without -q reads the whole list; -q can exit early and SIGPIPE jq, failing the pipeline under pipefail.
    if tables_of "${proj}" "${d}" | grep -Fx "${table}" >/dev/null; then echo "${d} ${i}"; return 0; fi
    i=$((i+1))
  done
  return 1
}

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
  [[ "$(jq -r '.open' <<<"${desc}")" == "true" ]] \
    || warn "billing account ${ba} is CLOSED — it exports no new data; only its existing export history can be connected"
  local parent
  parent=$(jq -r '.masterBillingAccount // empty' <<<"${desc}")
  parent="${parent#billingAccounts/}"
  if [[ -n "${parent}" ]]; then
    info "RESELLER SUB-ACCOUNT — parent ${parent}. The reseller may hold the admin role, not you."
  else
    info "direct billing account (no reseller parent)"
  fi

  local granted
  if ! granted=$(test_perms "https://cloudbilling.googleapis.com/v1/billingAccounts/${ba}:testIamPermissions" \
      billing.accounts.get billing.accounts.getIamPolicy billing.accounts.setIamPolicy billing.resourceAssociations.list); then
    fail "could not check your permissions on ${ba} ($(cat "${NOTE_F}")) — re-run this check"
    return
  fi

  # init.sh always runs 'gcloud billing accounts add-iam-policy-binding' (a policy read
  # then write), even when LumiTure already holds the role — so both are required.
  if has billing.accounts.setIamPolicy "${granted}" && has billing.accounts.getIamPolicy "${granted}"; then
    pass "can grant roles/billing.viewer to LumiTure (billing.accounts.getIamPolicy + setIamPolicy)"
  else
    local already=""
    if has billing.accounts.getIamPolicy "${granted}"; then
      already=$(gcloud billing accounts get-iam-policy "${ba}" --format=json 2>/dev/null \
        | jq -r --arg m "serviceAccount:${LUMITURE_SA}" '.bindings[]? | select(.role=="roles/billing.viewer") | .members[] | select(.==$m)')
    fi
    if [[ -n "${already}" ]]; then
      fail "LumiTure already holds roles/billing.viewer, but init.sh still re-applies it and stops there (after the dataset grants, before printing the form values). Run init.sh as a Billing Account Administrator of ${ba}, or tell LumiTure to finish this account by hand"
    elif [[ -n "${parent}" ]]; then
      fail "cannot grant roles/billing.viewer (needs Billing Account Administrator). Ask the reseller that owns ${parent} to grant roles/billing.viewer on ${ba} to ${LUMITURE_SA}"
    else
      fail "cannot grant roles/billing.viewer (needs Billing Account Administrator on ${ba})"
    fi
  fi
  has billing.resourceAssociations.list "${granted}" \
    && pass "can list projects linked to the BA (needed for export auto-detect)" \
    || warn "cannot list projects under the BA — init.sh will need --export-project, --detailed-usage-dataset and --pricing-dataset"

  # Locate the Detailed Usage Cost export by its table name, the way init.sh does.
  local table="gcp_billing_export_resource_v1_${ba//-/_}" proj="" ds="" pos="" hit p
  : >"${UNREAD_F}"
  if [[ -n "${EXPORT_PROJECT_ARG}" ]]; then
    proj="${EXPORT_PROJECT_ARG}"
    hit=$(find_table "${proj}" "${table}") && read -r ds pos <<<"${hit}"
  else
    local projects n=0 total
    projects=$(gcloud billing projects list --billing-account="${ba}" --format='value(projectId)' 2>/dev/null)
    total=$(wc -w <<<"${projects}" | tr -d ' ')
    info "scanning ${total} project(s) under the BA for ${table} (large accounts: pass --export-project to skip this) …"
    for p in ${projects}; do
      n=$((n+1))
      # Transient progress on a terminal only, so a saved report does not list every project.
      [[ -t 2 ]] && printf "\r  … %d/%d\033[K" "${n}" "${total}" >&2
      if hit=$(find_table "${p}" "${table}"); then
        proj="${p}"; read -r ds pos <<<"${hit}"; break
      fi
    done
    [[ -t 2 && ${total} -gt 0 ]] && printf "\r\033[K" >&2
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
  local rows
  rows=$(rows_of "${proj}:${ds}.${table}")
  if [[ -n "${rows}" && "${rows}" != "0" ]]; then
    pass "Detailed Usage Cost export → ${proj}:${ds} (${rows} rows)"
  else
    fail "Detailed Usage Cost export ${proj}:${ds}.${table} has no rows yet — init.sh stops on an empty export. Re-run once data lands (up to 24 h after enabling)"
  fi

  local pds="" ppos=""
  hit=$(find_table "${proj}" cloud_pricing_export) && read -r pds ppos <<<"${hit}"
  if [[ -n "${pds}" ]]; then
    rows=$(rows_of "${proj}:${pds}.cloud_pricing_export")
    if [[ -n "${rows}" && "${rows}" != "0" ]]; then
      pass "Pricing export → ${proj}:${pds} (${rows} rows)"
    else
      fail "Pricing export ${proj}:${pds}.cloud_pricing_export has no rows yet — init.sh stops on an empty Pricing table. Re-run once data lands (up to 48 h)"
    fi
  else
    local cfgs cfg disabled
    if ! cfgs=$(bq ls --transfer_config --transfer_location=us --project_id="${proj}" --format=json 2>/dev/null | json_only) \
       || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${cfgs:-[]}"; then
      fail "Pricing export not found in ${proj}, and its transfer configs could not be read — enable Pricing in Billing → Billing export → BigQuery export"
    else
      cfg=$(jq -r '.[]? | select(.displayName | test("Pricing"; "i")) | .name' <<<"${cfgs:-[]}" | head -1)
      if [[ -z "${cfg}" ]]; then
        fail "Pricing export not enabled in ${proj} — enable it in Billing → Billing export → BigQuery export → Pricing"
      else
        disabled=$(bq show --format=json --transfer_config "${cfg}" 2>/dev/null | json_only | jq -r '.disabled // false' 2>/dev/null)
        [[ "${disabled}" == "true" ]] \
          && fail "Pricing export is configured but its transfer is DISABLED — re-save it in Billing → Billing export → Pricing and complete the authorization prompt" \
          || fail "Pricing export is configured but has not delivered cloud_pricing_export yet (first load up to 48 h) — re-run this check later"
      fi
    fi
  fi

  # init.sh's auto-detect only sees the first 50 datasets of the project.
  local init_cmd="./init.sh --billing-account-id ${ba} --export-project ${proj} --detailed-usage-dataset ${ds} --pricing-dataset ${pds:-<pricing-dataset>}"
  if [[ ${pos} -ge ${INIT_DATASET_LIMIT} || ${ppos:-0} -ge ${INIT_DATASET_LIMIT} ]]; then
    warn "the export dataset sits beyond the first ${INIT_DATASET_LIMIT} datasets of ${proj}, so init.sh's auto-detect will miss it — run: ${init_cmd}"
  else
    info "if init.sh's auto-detect picks something else, pin it: ${init_cmd}"
  fi

  check_export_project "${proj}" "${ds}" "${pds}"
  check_scoping_project "${SCOPING_PROJECT_ARG:-${proj}}"
}

check_export_project() {
  local proj="$1" ds="$2" pds="$3"
  local granted out

  # Dry runs (free) of init.sh's two freshness queries prove bigquery.jobs.create in the
  # export project plus read access to every table they touch.
  dry_run() {
    bq query --dry_run --use_legacy_sql=false --project_id="${proj}" "$1" 2>&1
  }
  short_err() { tr '\n' ' ' <<<"$1" | sed 's/.*in query operation: //' | cut -c1-220; }
  if out=$(dry_run "SELECT MAX(export_time) FROM \`${proj}.${ds}.gcp_billing_export_resource_v1_*\`"); then
    pass "can run init.sh's Detailed Usage Cost freshness query in ${proj} (dry run)"
  else
    fail "cannot run init.sh's Detailed Usage Cost query in ${proj} — needs roles/bigquery.user on ${proj} + read on ${ds}: $(short_err "${out}")"
  fi
  if [[ -n "${pds}" ]]; then
    if out=$(dry_run "SELECT COUNT(*) FROM \`${proj}.${pds}.cloud_pricing_export\`"); then
      pass "can run init.sh's Pricing query in ${proj} (dry run)"
    else
      fail "cannot run init.sh's Pricing query in ${proj} — needs read on ${pds}: $(short_err "${out}")"
    fi
  fi

  # Granting READER on a dataset needs bigquery.datasets.update — project-level, or OWNER on the dataset.
  if ! granted=$(test_perms "https://cloudresourcemanager.googleapis.com/v1/projects/${proj}:testIamPermissions" \
      bigquery.datasets.update); then
    fail "could not check your BigQuery permissions on ${proj} ($(cat "${NOTE_F}")) — re-run this check"
    return
  fi
  local d acl
  for d in $(printf '%s\n' "${ds}" "${pds}" | awk 'NF && !seen[$0]++'); do
    if has bigquery.datasets.update "${granted}"; then
      pass "can grant LumiTure READER on ${proj}:${d}"
      continue
    fi
    acl=$(bq show --format=json "${proj}:${d}" 2>/dev/null | json_only)
    if jq -e --arg me "${ME}" '[.access[]? | select(.role=="OWNER" and ((.userByEmail // "") | ascii_downcase) == ($me|ascii_downcase))] | length > 0' >/dev/null 2>&1 <<<"${acl}"; then
      pass "can grant LumiTure READER on ${proj}:${d} (you are dataset OWNER)"
    elif jq -e '[.access[]? | select(.role=="OWNER" and (.groupByEmail or .domain or .specialGroup or .iamMember))] | length > 0' >/dev/null 2>&1 <<<"${acl}"; then
      fail "cannot verify you can grant READER on ${proj}:${d} — dataset OWNER is held only by a group/domain/special group, and membership can't be checked from here. Get roles/bigquery.dataOwner on the dataset (or project) for yourself"
    else
      fail "cannot grant LumiTure READER on ${proj}:${d} — needs roles/bigquery.dataOwner (or bigquery.admin) on the dataset or project"
    fi
  done
}

check_scoping_project() {
  local proj="$1"
  local granted msg
  if ! granted=$(test_perms "https://cloudresourcemanager.googleapis.com/v1/projects/${proj}:testIamPermissions" \
      resourcemanager.projects.getIamPolicy resourcemanager.projects.setIamPolicy); then
    msg="could not check your IAM permissions on scoping project ${proj} ($(cat "${NOTE_F}"))"
    if [[ ${WITH_USAGE} -eq 1 ]]; then fail "${msg}"; else warn "${msg}"; fi
    return
  fi
  if has resourcemanager.projects.setIamPolicy "${granted}" && has resourcemanager.projects.getIamPolicy "${granted}"; then
    pass "can grant roles/monitoring.viewer on scoping project ${proj} (usage / rightsizing)"
    return
  fi
  msg="cannot grant roles/monitoring.viewer on ${proj} (usage / rightsizing) — needs Project IAM Admin or Owner"
  if [[ ${WITH_USAGE} -eq 1 ]]; then fail "${msg}"; else warn "${msg}; billing works without it"; fi
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
