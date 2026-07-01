#!/usr/bin/env bash
# LumiTure GCP Onboarding — automated billing-data integration
#
# Automates 6 of the 7 in-product wizard steps for the GCP billing integration:
#   2. Identify Detailed Usage Cost dataset
#   3. Identify Pricing dataset
#   4. Grant LumiTure SA BigQuery Data Viewer
#   5. Verify SA can read
#   6. Collect form values
#   7. (Optional) Submit to LumiTure
#
# Step 1 — enabling Cloud Billing export to BigQuery — is Console-only per
# https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup
# This script pre-flight checks and fails fast if export is not detected.
#
# Usage:
#   init.sh [options]
#
# Required (or interactive prompt):
#   --billing-account-id     <NNNNNN-NNNNNN-NNNNNN>     Cloud Billing Account ID
#   --export-project         <project-id>                GCP project hosting billing export datasets
#   --detailed-usage-dataset <dataset-id>                BQ dataset for Detailed Usage Cost export
#   --pricing-dataset        <dataset-id>                BQ dataset for Pricing export
#
# Optional:
#   --grant-scope            project|dataset             default: dataset (tighter)
#   --with-usage             also grant roles/monitoring.viewer on the scoping project
#                            (usage/rightsizing metrics) + optional usage submit
#   --scoping-project        <project-id>                scoping project for usage metrics
#                                                        (default: --export-project)
#   --skip-billing           usage-only: skip all billing discovery/grants and do JUST
#                            the usage grant. Implies --with-usage; requires
#                            --scoping-project. For orgs already billing-onboarded.
#   --lumiture-sa            <email>                     default: prod SA (lumiture-client@tw-rd-app-finops-prod...)
#   --lumiture-api           <https://api.lumiture.ai>   for auto-submit; omit to skip submit
#   --lumiture-jwt           <token>                     provide to auto-submit; omit to finish in the wizard
#   --discover-only          run discovery + report only; no grants, no submit
#   --dry-run                print commands without executing
#   --verbose                set -x
#   --help                   print this and exit

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants — the LumiTure service account each environment grants read access to.
# These SA emails are public by design (also shown in the in-product wizard).
# -----------------------------------------------------------------------------

readonly LUMITURE_SA_PROD="lumiture-client@tw-rd-app-finops-prod.iam.gserviceaccount.com"
readonly LUMITURE_API_PROD="https://api.lumiture.ai"
readonly REQUIRED_ROLE="roles/bigquery.dataViewer"
# Usage/rightsizing: LumiTure reads Cloud Monitoring metrics (CPU utilization etc.)
# from a scoping project — needs roles/monitoring.viewer there.
readonly USAGE_ROLE="roles/monitoring.viewer"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()     { printf "%b %s\n" "${c_blu}[lumiture]${c_off}" "$*" >&2; }
ok()      { printf "%b %s\n" "${c_grn}[ ok ]${c_off}"     "$*" >&2; }
warn()    { printf "%b %s\n" "${c_ylw}[warn]${c_off}"     "$*" >&2; }
err()     { printf "%b %s\n" "${c_red}[err ]${c_off}"     "$*" >&2; }
die()     { err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------

BILLING_ACCOUNT_ID=""
EXPORT_PROJECT_ID=""
DETAILED_USAGE_DATASET=""
PRICING_DATASET=""
GRANT_SCOPE="dataset"
WITH_USAGE=0
SKIP_BILLING=0
SCOPING_PROJECT_ID=""
LUMITURE_SA=""
LUMITURE_API=""
LUMITURE_JWT=""
DISCOVER_ONLY=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --billing-account-id) BILLING_ACCOUNT_ID="$2"; shift 2 ;;
    --export-project) EXPORT_PROJECT_ID="$2"; shift 2 ;;
    --detailed-usage-dataset) DETAILED_USAGE_DATASET="$2"; shift 2 ;;
    --pricing-dataset) PRICING_DATASET="$2"; shift 2 ;;
    --grant-scope) GRANT_SCOPE="$2"; shift 2 ;;
    --with-usage) WITH_USAGE=1; shift ;;
    --skip-billing) SKIP_BILLING=1; shift ;;
    --scoping-project) SCOPING_PROJECT_ID="$2"; shift 2 ;;
    --lumiture-sa) LUMITURE_SA="$2"; shift 2 ;;
    --lumiture-api) LUMITURE_API="$2"; shift 2 ;;
    --lumiture-jwt) LUMITURE_JWT="$2"; shift 2 ;;
    --discover-only) DISCOVER_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) set -x; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 — try --help" ;;
  esac
done

# Defaults target LumiTure production; override with --lumiture-sa / --lumiture-api if needed.
[[ -n "${LUMITURE_SA}" ]] || LUMITURE_SA="${LUMITURE_SA_PROD}"
[[ -n "${LUMITURE_API}" ]] || LUMITURE_API="${LUMITURE_API_PROD}"

# -----------------------------------------------------------------------------
# Run helper — respects --dry-run
# -----------------------------------------------------------------------------

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

# Filter bq stdout WARNING leaks (cosmetic)
bq_show_clean() {
  bq show --format=prettyjson "$1" 2>/dev/null | sed -n '/^{/,$p'
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight() {
  log "Pre-flight checks…"

  command -v gcloud >/dev/null || die "gcloud CLI not found"
  command -v jq >/dev/null || die "jq not found — install via 'brew install jq' / 'apt install jq'"
  # bq + ADC are only needed for the billing reads; usage-only mode skips them.
  if [[ "${SKIP_BILLING}" -eq 0 ]]; then
    command -v bq >/dev/null || die "bq CLI not found"
    ok "Required tools installed (gcloud, bq, jq)"
  else
    ok "Required tools installed (gcloud, jq) — usage-only, bq not needed"
  fi

  local active_acct
  active_acct=$(gcloud config get-value account 2>/dev/null || true)
  [[ -n "${active_acct}" ]] || die "No active gcloud account — run 'gcloud auth login' first"
  ok "Active gcloud account: ${active_acct}"

  if [[ "${SKIP_BILLING}" -eq 0 ]]; then
    gcloud auth application-default print-access-token >/dev/null 2>&1 \
      || die "Application Default Credentials not set — run 'gcloud auth application-default login'"
    ok "ADC configured"
  fi
}

# -----------------------------------------------------------------------------
# Phase 1 — Discovery
# -----------------------------------------------------------------------------

discover_billing_account() {
  log "Phase 1.1 — Discovering billing accounts visible to ${active_acct:-current account}…"
  local accounts_json
  accounts_json=$(gcloud billing accounts list --format=json 2>/dev/null)
  local count
  count=$(echo "${accounts_json}" | jq 'length')

  if [[ "${count}" -eq 0 ]]; then
    die "No billing accounts visible — ensure you have 'roles/billing.viewer' on the customer's BA"
  fi

  echo "${accounts_json}" | jq -r '.[] | "  - \(.name | sub("billingAccounts/"; ""))  \(.displayName)"' >&2

  if [[ -z "${BILLING_ACCOUNT_ID}" ]]; then
    if [[ "${count}" -eq 1 ]]; then
      BILLING_ACCOUNT_ID=$(echo "${accounts_json}" | jq -r '.[0].name | sub("billingAccounts/"; "")')
      ok "Only one BA visible; auto-selected: ${BILLING_ACCOUNT_ID}"
    else
      die "Multiple billing accounts visible; specify --billing-account-id"
    fi
  fi
}

discover_export_project() {
  log "Phase 1.2 — Confirming billing-export-to-BQ enablement…"

  if [[ -z "${EXPORT_PROJECT_ID}" ]]; then
    warn "No --export-project specified. The script cannot auto-discover which project hosts the billing export — billing-export config is Console-only and not exposed via API."
    warn "Please pass --export-project <id> based on the customer's Cloud Console: Billing → Billing export → BigQuery export → 'Project'"
    die "Missing --export-project"
  fi

  if [[ -z "${DETAILED_USAGE_DATASET}" || -z "${PRICING_DATASET}" ]]; then
    log "Listing BQ datasets in ${EXPORT_PROJECT_ID} to surface candidates…"
    bq ls --project_id="${EXPORT_PROJECT_ID}" 2>&1 | grep -v "WARNING\|Could not setup\|may not be writable\|To learn more" | head -20 >&2 || true
    warn "Specify --detailed-usage-dataset and --pricing-dataset based on the list above"
    [[ -n "${DETAILED_USAGE_DATASET}" && -n "${PRICING_DATASET}" ]] || die "Missing dataset args"
  fi

  ok "Will use export project: ${EXPORT_PROJECT_ID}"
  ok "  Detailed Usage Cost dataset: ${DETAILED_USAGE_DATASET}"
  ok "  Pricing dataset: ${PRICING_DATASET}"
}

# Run a BQ scalar query, separating stdout/stderr and exit code.
# Sets globals: BQ_OUT, BQ_ERR, BQ_RC
bq_scalar_query() {
  local sql="$1"
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  BQ_OUT=$(bq query --use_legacy_sql=false --project_id="${EXPORT_PROJECT_ID}" --format=csv --quiet "${sql}" 2>"${stderr_file}" | tail -n 1 | tr -d '"')
  BQ_RC=$?
  set -e
  BQ_ERR=$(head -3 "${stderr_file}" | tr '\n' ' ')
  rm -f "${stderr_file}"
}

validate_freshness() {
  log "Phase 1.3 — Validating dataset freshness…"

  bq_scalar_query "SELECT MAX(export_time) FROM \`${EXPORT_PROJECT_ID}.${DETAILED_USAGE_DATASET}.gcp_billing_export_resource_v1_*\`"

  if [[ "${BQ_RC}" -ne 0 ]]; then
    warn "Detailed Usage Cost query failed (exit ${BQ_RC}). Likely: table missing, billing export not enabled, or wrong project."
    warn "BQ error: ${BQ_ERR}"
    [[ "${DISCOVER_ONLY}" -eq 1 || "${DRY_RUN}" -eq 1 ]] || die "Freshness check failed — cannot proceed to integration"
  elif [[ -z "${BQ_OUT}" || "${BQ_OUT}" == "NULL" ]]; then
    warn "Detailed Usage Cost has no export_time data — export may not be enabled yet, OR the table pattern differs from gcp_billing_export_resource_v1_*"
    warn "Resolve: Cloud Console → Billing → Billing export → BigQuery export → 'Detailed usage cost' is ENABLED; wait up to 24h for first data."
    [[ "${DISCOVER_ONLY}" -eq 1 || "${DRY_RUN}" -eq 1 ]] || die "Freshness check failed — cannot proceed to integration"
  else
    ok "Detailed Usage Cost latest export_time: ${BQ_OUT}"
  fi

  bq_scalar_query "SELECT COUNT(*) FROM \`${EXPORT_PROJECT_ID}.${PRICING_DATASET}.cloud_pricing_export\`"

  if [[ "${BQ_RC}" -ne 0 ]]; then
    warn "Pricing query failed (exit ${BQ_RC}). The cloud_pricing_export table is missing."
    warn "BQ error: ${BQ_ERR}"
    diagnose_pricing_transfer
    [[ "${DISCOVER_ONLY}" -eq 1 || "${DRY_RUN}" -eq 1 ]] || die "Pricing freshness check failed"
  elif [[ -z "${BQ_OUT}" || "${BQ_OUT}" == "0" ]]; then
    warn "Pricing dataset has no rows in cloud_pricing_export."
    diagnose_pricing_transfer
    [[ "${DISCOVER_ONLY}" -eq 1 || "${DRY_RUN}" -eq 1 ]] || die "Pricing freshness check failed"
  else
    ok "Pricing rows: ${BQ_OUT}"
  fi
}

# Pricing export is delivered via a BigQuery Data Transfer config that can be
# silently created in a DISABLED state (Console authorization step skipped).
# Detect that case and give the operator the exact fix.
diagnose_pricing_transfer() {
  local cfg
  cfg=$(bq ls --transfer_config --transfer_location=us --project_id="${EXPORT_PROJECT_ID}" --format=json 2>/dev/null \
    | jq -r '.[] | select(.displayName | test("Pricing"; "i")) | .name' | head -1)
  if [[ -z "${cfg}" ]]; then
    warn "  → No 'Pricing BigQuery Transfer' config found. Pricing export was never configured."
    warn "    Fix: Console → Billing → Billing export → BigQuery export → enable 'Pricing'."
    return
  fi
  local disabled
  disabled=$(bq show --format=prettyjson --transfer_config "${cfg}" 2>/dev/null | sed -n '/^{/,$p' | jq -r '.disabled // false')
  if [[ "${disabled}" == "true" ]]; then
    warn "  → DIAGNOSIS: Pricing transfer config exists but is DISABLED (never ran)."
    warn "    This is the silent-disabled-transfer gotcha. The CLI cannot enable a"
    warn "    billing-managed transfer — re-do it in the Console:"
    warn "    Billing → Billing export → BigQuery export → Pricing → Edit settings →"
    warn "    Save → COMPLETE the authorization prompt. Then wait ~24h."
  else
    warn "  → Pricing transfer is enabled but hasn't delivered yet — likely just needs more time (~24h)."
  fi
}

# -----------------------------------------------------------------------------
# Phase 2 — IAM grant
# -----------------------------------------------------------------------------

grant_iam_project_level() {
  log "Phase 2 — Granting ${REQUIRED_ROLE} on PROJECT ${EXPORT_PROJECT_ID} to ${LUMITURE_SA}…"
  run gcloud projects add-iam-policy-binding "${EXPORT_PROJECT_ID}" \
    --member="serviceAccount:${LUMITURE_SA}" \
    --role="${REQUIRED_ROLE}" \
    --condition=None \
    --quiet
  ok "Project-level grant applied"
}

grant_iam_dataset_level() {
  local dataset="$1"
  log "Phase 2 — Granting READER on DATASET ${EXPORT_PROJECT_ID}:${dataset} to ${LUMITURE_SA}…"

  local tmp_iam tmp_iam_new
  tmp_iam=$(mktemp /tmp/lumiture-iam-XXXXXX.json)
  tmp_iam_new=$(mktemp /tmp/lumiture-iam-new-XXXXXX.json)

  bq_show_clean "${EXPORT_PROJECT_ID}:${dataset}" > "${tmp_iam}"
  jq --arg sa "${LUMITURE_SA}" '
    .access = (
      (.access // []) +
      (if any(.access[]?; .userByEmail == $sa and .role == "READER")
       then []
       else [{role: "READER", userByEmail: $sa}]
       end)
    )' "${tmp_iam}" > "${tmp_iam_new}"

  run bq update --source "${tmp_iam_new}" "${EXPORT_PROJECT_ID}:${dataset}"

  rm -f "${tmp_iam}" "${tmp_iam_new}"
  ok "Dataset-level grant applied on ${dataset}"
}

grant_iam_billing_viewer() {
  # REQUIRED in addition to the BQ dataViewer grant: LumiTure's integration
  # create() validation calls get_account_name() via the Cloud Billing API, which
  # needs roles/billing.viewer on the billing account. Without it the wizard
  # rejects submit with "Permission Denied" even when the dataset grant is present.
  log "Phase 2 — Granting roles/billing.viewer on BILLING ACCOUNT ${BILLING_ACCOUNT_ID} to ${LUMITURE_SA}…"
  run gcloud billing accounts add-iam-policy-binding "${BILLING_ACCOUNT_ID}" \
    --member="serviceAccount:${LUMITURE_SA}" \
    --role="roles/billing.viewer" \
    --quiet
  ok "Billing-account-level grant applied"
}

validate_grant() {
  local dataset="$1"
  log "Phase 2.v — Verifying grant on ${EXPORT_PROJECT_ID}:${dataset}…"
  local result
  result=$(bq_show_clean "${EXPORT_PROJECT_ID}:${dataset}" \
    | jq --arg sa "${LUMITURE_SA}" '[.access[]? | select(.userByEmail == $sa)] | length')
  if [[ "${result:-0}" -ge 1 ]]; then
    ok "Confirmed ${LUMITURE_SA} is bound on ${dataset}"
  else
    die "Grant validation failed on ${dataset} — ${LUMITURE_SA} not found in access[]"
  fi
}

# -----------------------------------------------------------------------------
# Phase 3 — Output / Submit
# -----------------------------------------------------------------------------

emit_form_values() {
  log "Phase 3 — Form values ready for LumiTure wizard or API:"
  cat <<EOF
{
  "billing_account_id": "${BILLING_ACCOUNT_ID}",
  "detailed_usage_cost": {
    "project_id": "${EXPORT_PROJECT_ID}",
    "dataset_id": "${DETAILED_USAGE_DATASET}"
  },
  "pricing": {
    "project_id": "${EXPORT_PROJECT_ID}",
    "dataset_id": "${PRICING_DATASET}"
  }
}
EOF
}

submit_to_lumiture() {
  [[ -n "${LUMITURE_API}" ]] || { log "Skipping auto-submit (no --lumiture-api set)"; return 0; }
  [[ -n "${LUMITURE_JWT}" ]] || { ok "Grants done. No --lumiture-jwt → skipping auto-submit; paste the form values above into the wizard to finish."; return 0; }

  log "Phase 3.s — Submitting integration to ${LUMITURE_API}…"
  local payload
  payload=$(cat <<EOF
{
  "billing_account_id": "${BILLING_ACCOUNT_ID}",
  "detailed_usage_cost": {"project_id": "${EXPORT_PROJECT_ID}", "dataset_id": "${DETAILED_USAGE_DATASET}"},
  "pricing": {"project_id": "${EXPORT_PROJECT_ID}", "dataset_id": "${PRICING_DATASET}"}
}
EOF
)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: would POST ${LUMITURE_API}/platforms/gcp/billing/integration"
    return 0
  fi

  local http_status
  http_status=$(curl -s -o /tmp/lumiture-submit.out -w '%{http_code}' \
    -X POST "${LUMITURE_API}/platforms/gcp/billing/integration" \
    -H "Authorization: Bearer ${LUMITURE_JWT}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
    ok "LumiTure integration created (HTTP ${http_status})"
    cat /tmp/lumiture-submit.out >&2
  else
    err "LumiTure submit failed: HTTP ${http_status}"
    cat /tmp/lumiture-submit.out >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Phase 4 — Usage / rightsizing (opt-in: --with-usage)
# Usage data is Cloud Monitoring metrics (CPU utilization etc.), NOT the
# "Detailed Usage Cost" billing export. LumiTure reads them from a scoping
# project, so the SA needs roles/monitoring.viewer there. Then the in-product
# usage step (POST /platforms/gcp/usage/integration) registers the scoping project.
# -----------------------------------------------------------------------------

grant_usage_monitoring() {
  local scoping="${SCOPING_PROJECT_ID:-${EXPORT_PROJECT_ID}}"
  [[ -n "${scoping}" ]] || die "--with-usage needs a scoping project (--scoping-project or --export-project)"

  log "Phase 4 — Granting ${USAGE_ROLE} on SCOPING PROJECT ${scoping} to ${LUMITURE_SA} (usage metrics)…"
  run gcloud projects add-iam-policy-binding "${scoping}" \
    --member="serviceAccount:${LUMITURE_SA}" \
    --role="${USAGE_ROLE}" \
    --condition=None \
    --quiet
  ok "Monitoring-viewer grant applied on scoping project ${scoping}"

  log "Phase 4 — Usage form value: scoping_project_id = ${scoping}"

  # Optional auto-submit of the usage integration (parallels billing submit).
  [[ -n "${LUMITURE_API}" && -n "${LUMITURE_JWT}" ]] || { ok "Grant done. Enter scoping_project_id='${scoping}' in the LumiTure usage step to finish."; return 0; }
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: would POST ${LUMITURE_API}/platforms/gcp/usage/integration"
    return 0
  fi
  local http_status
  http_status=$(curl -s -o /tmp/lumiture-usage-submit.out -w '%{http_code}' \
    -X POST "${LUMITURE_API}/platforms/gcp/usage/integration" \
    -H "Authorization: Bearer ${LUMITURE_JWT}" \
    -H "Content-Type: application/json" \
    -d "{\"scoping_project_id\": \"${scoping}\"}")
  if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
    ok "LumiTure usage integration created (HTTP ${http_status})"
  else
    warn "Usage submit returned HTTP ${http_status} — finish in the wizard with scoping_project_id='${scoping}'"
    cat /tmp/lumiture-usage-submit.out >&2
  fi
}

# -----------------------------------------------------------------------------
# Main flow
# -----------------------------------------------------------------------------

main() {
  preflight

  # Usage-only mode: skip all billing work, do just the monitoring grant + submit.
  if [[ "${SKIP_BILLING}" -eq 1 ]]; then
    [[ -n "${SCOPING_PROJECT_ID}" ]] || die "--skip-billing requires --scoping-project (no --export-project to default from in usage-only mode)"
    WITH_USAGE=1
    log "--skip-billing — usage-only run (no billing discovery/grants)"
    grant_usage_monitoring
    ok "GCP usage-only onboarding complete"
    return 0
  fi

  discover_billing_account
  discover_export_project
  validate_freshness

  if [[ "${DISCOVER_ONLY}" -eq 1 ]]; then
    log "--discover-only mode — emitting collected values, exiting before grant/submit"
    emit_form_values
    exit 0
  fi

  case "${GRANT_SCOPE}" in
    project)
      grant_iam_project_level
      ;;
    dataset)
      grant_iam_dataset_level "${DETAILED_USAGE_DATASET}"
      grant_iam_dataset_level "${PRICING_DATASET}"
      validate_grant "${DETAILED_USAGE_DATASET}"
      validate_grant "${PRICING_DATASET}"
      ;;
    *) die "Invalid --grant-scope: ${GRANT_SCOPE} (project|dataset)" ;;
  esac

  grant_iam_billing_viewer

  emit_form_values
  submit_to_lumiture
  [[ "${WITH_USAGE}" -eq 1 ]] && grant_usage_monitoring
  ok "GCP onboarding complete"
}

main "$@"
