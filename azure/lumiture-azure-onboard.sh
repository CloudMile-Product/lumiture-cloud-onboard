#!/usr/bin/env bash
# LumiTure Azure Onboarding — automated billing-data integration
#
# Automates the customer-side grants for the Azure billing integration:
#   1. Verify LumiTure's multi-tenant service principal is consented in the tenant
#   2. Ensure a storage account + container exist for the Cost Management export
#   3. Grant LumiTure SP "Cost Management Reader" on the subscription
#   4. Grant LumiTure SP "Storage Blob Data Reader" on the export storage account
#   5. Create the daily Cost Management export(s) (actual cost; optional FOCUS)
#   6. Collect form values
#   7. (Optional) Submit to LumiTure
#
# Step 0 — granting ADMIN CONSENT to LumiTure's service principal — is a
# browser-only Microsoft flow (the "Connect Azure" button in the LumiTure
# wizard → admin-consent redirect). It cannot be scripted; this script
# pre-flight checks for the consented SP and fails fast if it's missing.
# This mirrors the GCP script's "enable billing export = Console-only" gate.
#
# Usage:
#   lumiture-azure-onboard.sh [options]
#
# Required (or interactive prompt):
#   --subscription-id   <GUID>          Azure subscription to onboard
#   --storage-account   <name>          Storage account for the cost export (created if absent)
#   --storage-rg        <name>          Resource group holding the storage account (created if absent)
#
# Optional:
#   --tenant-id         <GUID>          default: tenant of the active `az` login
#   --location          <region>        default: eastasia (used only when creating resources)
#   --container         <name>          default: billing-export
#   --export-name       <name>          default: daily-actual-cost
#   --with-focus                        also create a FOCUS-format export (daily-focus-cost)
#   --with-usage                        also create+assign the usage custom role (VM + Monitor
#                                       metrics read) for rightsizing/usage data — billing alone
#                                       does not need it; opt in for full FinOps
#   --lumiture-app-id   <GUID>          default: prod LumiTure multi-tenant SP app id
#   --lumiture-api      <https://api.lumiture.ai>   for auto-submit; omit to skip submit
#   --lumiture-jwt      <token>         provide to auto-submit; omit to finish in the wizard
#   --event-trigger-url <url>           LumiTure billing event-trigger URL (the Azure Function
#                                       webhook). Required for billing DATA to flow. If omitted,
#                                       fetched from the API when --lumiture-api + --lumiture-jwt
#                                       are given. Env-specific (NOT a public constant).
#   --event-sub-name    <name>          Event Grid subscription name (default: lumiture-billing-export)
#   --skip-event-subscription           do not create the Event Grid subscription
#   --discover-only     run discovery + report only; no grants, no export, no submit
#   --skip-export       do the grants but do not create the Cost Management export
#   --dry-run           print commands without executing
#   --verbose           set -x
#   --help              print this and exit

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants — LumiTure's multi-tenant service principal each environment grants
# read access to. The App (client) ID is public by design (also shown in the
# in-product wizard), analogous to the GCP read-only service-account email.
# -----------------------------------------------------------------------------

# LumiTure's PROD Azure multi-tenant SP App (client) ID — public by design (it's
# also the Microsoft sign-in client id, shown in the in-product wizard). NOT a
# secret. Override with --lumiture-app-id for non-production environments.
readonly LUMITURE_APP_ID_PROD="c871cf6f-dd8d-487a-a908-a66245655b0e"
readonly LUMITURE_API_PROD="https://api.lumiture.ai"
readonly LUMITURE_WIZARD_URL="https://app.lumiture.ai/authorization/billing-data-integration/azure"
readonly ROLE_COST_READER="Cost Management Reader"
readonly ROLE_BLOB_READER="Storage Blob Data Reader"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()  { printf "%b %s\n" "${c_blu}[lumiture]${c_off}" "$*" >&2; }
ok()   { printf "%b %s\n" "${c_grn}[ ok ]${c_off}"     "$*" >&2; }
warn() { printf "%b %s\n" "${c_ylw}[warn]${c_off}"     "$*" >&2; }
err()  { printf "%b %s\n" "${c_red}[err ]${c_off}"     "$*" >&2; }
die()  { err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------

SUBSCRIPTION_ID=""
TENANT_ID=""
STORAGE_ACCOUNT=""
STORAGE_RG=""
LOCATION="eastasia"
CONTAINER="billing-export"
EXPORT_NAME="daily-actual-cost"
WITH_FOCUS=0
WITH_USAGE=0
EVENT_TRIGGER_URL=""
EVENT_SUB_NAME="lumiture-billing-export"
SKIP_EVENT_SUBSCRIPTION=0
LUMITURE_APP_ID=""
LUMITURE_API=""
LUMITURE_JWT=""
DISCOVER_ONLY=0
SKIP_EXPORT=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --storage-account) STORAGE_ACCOUNT="$2"; shift 2 ;;
    --storage-rg) STORAGE_RG="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --export-name) EXPORT_NAME="$2"; shift 2 ;;
    --with-focus) WITH_FOCUS=1; shift ;;
    --with-usage) WITH_USAGE=1; shift ;;
    --event-trigger-url) EVENT_TRIGGER_URL="$2"; shift 2 ;;
    --event-sub-name) EVENT_SUB_NAME="$2"; shift 2 ;;
    --skip-event-subscription) SKIP_EVENT_SUBSCRIPTION=1; shift ;;
    --lumiture-app-id) LUMITURE_APP_ID="$2"; shift 2 ;;
    --lumiture-api) LUMITURE_API="$2"; shift 2 ;;
    --lumiture-jwt) LUMITURE_JWT="$2"; shift 2 ;;
    --discover-only) DISCOVER_ONLY=1; shift ;;
    --skip-export) SKIP_EXPORT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) set -x; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 — try --help" ;;
  esac
done

# Defaults target LumiTure production; override with --lumiture-app-id / --lumiture-api if needed.
[[ -n "${LUMITURE_APP_ID}" ]] || LUMITURE_APP_ID="${LUMITURE_APP_ID_PROD}"
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

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight() {
  log "Pre-flight checks…"

  command -v az >/dev/null || die "Azure CLI (az) not found — Azure Cloud Shell has it preinstalled"
  command -v jq >/dev/null || die "jq not found — install via 'brew install jq' / 'apt install jq'"
  ok "Required tools installed (az, jq)"

  local acct_json
  acct_json=$(az account show -o json 2>/dev/null) \
    || die "Not logged in — run 'az login' first (Azure Cloud Shell logs you in automatically)"

  local active_user active_tenant active_sub
  active_user=$(echo "${acct_json}" | jq -r '.user.name')
  active_tenant=$(echo "${acct_json}" | jq -r '.tenantId')
  active_sub=$(echo "${acct_json}" | jq -r '.id')
  ok "Active az account: ${active_user} (tenant ${active_tenant})"

  [[ -n "${TENANT_ID}" ]] || TENANT_ID="${active_tenant}"
  [[ -n "${SUBSCRIPTION_ID}" ]] || SUBSCRIPTION_ID="${active_sub}"

  log "Setting active subscription to ${SUBSCRIPTION_ID}…"
  run az account set --subscription "${SUBSCRIPTION_ID}"
  ok "Subscription set: ${SUBSCRIPTION_ID}"

  [[ "${LUMITURE_APP_ID}" != "REPLACE_WITH_LUMITURE_AZURE_APP_ID" ]] \
    || die "LumiTure App ID is unset — pass --lumiture-app-id <GUID> (shown in the LumiTure Azure wizard) or set LUMITURE_APP_ID_PROD in this script"
}

# -----------------------------------------------------------------------------
# Phase 0 — Confirm LumiTure SP is consented in this tenant (browser-only step)
# Sets global: SP_OBJECT_ID
# -----------------------------------------------------------------------------

verify_sp_consented() {
  log "Phase 0 — Verifying LumiTure service principal (${LUMITURE_APP_ID}) is consented in tenant ${TENANT_ID}…"
  SP_OBJECT_ID=$(az ad sp show --id "${LUMITURE_APP_ID}" --query id -o tsv 2>/dev/null || true)

  if [[ -z "${SP_OBJECT_ID}" ]]; then
    err "LumiTure's service principal is NOT yet present in your tenant."
    warn "This one step is browser-only (Microsoft admin consent) and cannot be scripted:"
    warn "  1. Open the LumiTure wizard: ${LUMITURE_WIZARD_URL}"
    warn "     (or click 'Connect Azure' in the LumiTure app)"
    warn "  2. Enter this subscription (${SUBSCRIPTION_ID}); you'll be redirected to Microsoft."
    warn "  3. Sign in as a tenant admin and Accept the consent prompt."
    warn "  4. Re-run this script — the SP will then be assignable."
    die "Admin consent required before grants can be applied"
  fi
  ok "LumiTure SP is consented (objectId ${SP_OBJECT_ID})"
}

# -----------------------------------------------------------------------------
# Phase 1 — Ensure export storage (account + container) exists
# Sets global: STORAGE_ACCOUNT_ID
# -----------------------------------------------------------------------------

ensure_storage() {
  [[ -n "${STORAGE_ACCOUNT}" ]] || die "Missing --storage-account (destination for the cost export)"
  [[ -n "${STORAGE_RG}" ]] || die "Missing --storage-rg (resource group for the storage account)"

  log "Phase 1 — Ensuring resource group ${STORAGE_RG} exists…"
  if ! az group show -n "${STORAGE_RG}" -o none 2>/dev/null; then
    run az group create -n "${STORAGE_RG}" -l "${LOCATION}" -o none
    ok "Created resource group ${STORAGE_RG} (${LOCATION})"
  else
    ok "Resource group ${STORAGE_RG} exists"
  fi

  log "Phase 1 — Ensuring storage account ${STORAGE_ACCOUNT} exists…"
  if ! az storage account show -n "${STORAGE_ACCOUNT}" -g "${STORAGE_RG}" -o none 2>/dev/null; then
    run az storage account create -n "${STORAGE_ACCOUNT}" -g "${STORAGE_RG}" \
      -l "${LOCATION}" --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o none
    ok "Created storage account ${STORAGE_ACCOUNT}"
  else
    ok "Storage account ${STORAGE_ACCOUNT} exists"
  fi

  STORAGE_ACCOUNT_ID=$(az storage account show -n "${STORAGE_ACCOUNT}" -g "${STORAGE_RG}" --query id -o tsv 2>/dev/null || true)
  [[ -n "${STORAGE_ACCOUNT_ID}" || "${DRY_RUN}" -eq 1 ]] || die "Could not resolve storage account id"

  log "Phase 1 — Ensuring container ${CONTAINER} exists…"
  run az storage container create --name "${CONTAINER}" \
    --account-name "${STORAGE_ACCOUNT}" --auth-mode login -o none
  ok "Container ${CONTAINER} ready"

  log "Phase 1 — Registering Microsoft.CostManagementExports provider…"
  run az provider register --namespace Microsoft.CostManagementExports -o none
  ok "Provider registration requested"
}

# -----------------------------------------------------------------------------
# Phase 2 — RBAC grants to the LumiTure SP
# -----------------------------------------------------------------------------

grant_cost_reader() {
  log "Phase 2 — Granting '${ROLE_COST_READER}' on subscription ${SUBSCRIPTION_ID} to LumiTure SP…"
  run az role assignment create \
    --assignee-object-id "${SP_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_COST_READER}" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    -o none
  ok "Subscription-level '${ROLE_COST_READER}' applied"
}

grant_blob_reader() {
  log "Phase 2 — Granting '${ROLE_BLOB_READER}' on storage account ${STORAGE_ACCOUNT} to LumiTure SP…"
  run az role assignment create \
    --assignee-object-id "${SP_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_BLOB_READER}" \
    --scope "${STORAGE_ACCOUNT_ID}" \
    -o none
  ok "Storage-level '${ROLE_BLOB_READER}' applied"
}

validate_grants() {
  log "Phase 2.v — Verifying role assignments for LumiTure SP…"
  local cnt
  cnt=$(az role assignment list --assignee "${SP_OBJECT_ID}" \
        --scope "/subscriptions/${SUBSCRIPTION_ID}" \
        --query "[?roleDefinitionName=='${ROLE_COST_READER}'] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "${cnt:-0}" -ge 1 ]]; then
    ok "Confirmed '${ROLE_COST_READER}' bound on subscription"
  else
    [[ "${DRY_RUN}" -eq 1 ]] || die "Grant validation failed — '${ROLE_COST_READER}' not found for SP ${SP_OBJECT_ID}"
  fi
}

# -----------------------------------------------------------------------------
# Phase 2.5 — Cost Management export(s)
# Hard contract with LumiTure's billing-event copy-function: it reads the customer
# export from container "billing-export" under the fixed prefixes cost/daily-actual-cost/
# (and cost/daily-focus-cost/ for FOCUS). So we root the export at "cost" and name each
# export after its subdir (daily-actual-cost / daily-focus-cost) — the export name forms
# the path segment after the rootFolder. (The {tenant}/{sub}/{YYYYMM} layout is the
# LumiTure-side blob path the *transfer* command reads, NOT the customer export path.)
# -----------------------------------------------------------------------------

create_export() {
  local name="$1" export_type="$2"   # $3 (legacy subdir) unused: rootFolderPath is "cost", the name forms the subdir
  # Schedule start must be in the future. GNU date (Cloud Shell) first, BSD/macOS fallback.
  local from_date to_date
  from_date=$(date -u -d '+1 day' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v+1d +%Y-%m-%dT00:00:00Z)
  to_date=$(date -u -d '+5 years' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v+5y +%Y-%m-%dT00:00:00Z)

  # Create via the ARM REST API, not the `az costmanagement` extension: the extension
  # prompts to self-install and rejects FOCUS (only Usage/ActualCost/AmortizedCost).
  # FOCUS is accepted only on 2023-07-01-preview (all stable versions reject it, and
  # reject a dataVersion property); ActualCost/AmortizedCost use the stable 2023-11-01.
  local api_version dataset
  if [[ "${export_type}" == "FocusCost" ]]; then
    api_version="2023-07-01-preview"
    dataset='"granularity": "Daily", "configuration": { "dataVersion": "1.0" }'
  else
    api_version="2023-11-01"
    dataset='"granularity": "Daily"'
  fi

  log "Phase 2.5 — Creating ${export_type} export '${name}' → ${STORAGE_ACCOUNT}/${CONTAINER}/cost/${name} (daily ${from_date}…${to_date})…"
  local url body
  url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/exports/${name}?api-version=${api_version}"
  body="{\"properties\":{\"schedule\":{\"status\":\"Active\",\"recurrence\":\"Daily\",\"recurrencePeriod\":{\"from\":\"${from_date}\",\"to\":\"${to_date}\"}},\"format\":\"Csv\",\"deliveryInfo\":{\"destination\":{\"resourceId\":\"${STORAGE_ACCOUNT_ID}\",\"container\":\"${CONTAINER}\",\"rootFolderPath\":\"cost\"}},\"definition\":{\"type\":\"${export_type}\",\"timeframe\":\"MonthToDate\",\"dataSet\":{${dataset}}}}}"
  if run az rest --method PUT --url "${url}" --headers "Content-Type=application/json" --body "${body}" -o none; then
    ok "Export '${name}' created (first Azure run lands in ~24h)"
    log "  NOTE: the export alone doesn't deliver data — LumiTure ingests from its own blob"
    log "  via the event trigger. Phase 2.7 wires that (needs --event-trigger-url or a JWT)."
  else
    warn "Export '${name}' create failed — see the az error above."
  fi
}

# -----------------------------------------------------------------------------
# Phase 2.6 — Usage custom role (opt-in: --with-usage)
# Usage/rightsizing data needs the SP to read VMs + Azure Monitor metrics, which
# Cost Management Reader does NOT cover. We create + assign a custom role for this.
# The role name is cosmetic; the LumiTure usage-check validates by listing VMs, so
# what matters is the action set below covering VM read + Monitor metrics read.
# -----------------------------------------------------------------------------

grant_usage_role() {
  local role_name="LumiTure FinOps Reader"
  local scope="/subscriptions/${SUBSCRIPTION_ID}"
  local role_def
  role_def=$(cat <<JSON
{
  "Name": "${role_name}",
  "IsCustom": true,
  "Description": "LumiTure FinOps usage-metrics reader (VM inventory + Azure Monitor metrics).",
  "Actions": [
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.Insights/Metrics/Read",
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "AssignableScopes": ["${scope}"]
}
JSON
)
  log "Phase 2.6 — Ensuring custom usage role '${role_name}' on subscription…"
  if az role definition list --name "${role_name}" --scope "${scope}" --query "[0].roleName" -o tsv --only-show-errors 2>/dev/null | grep -q .; then
    run az role definition update --role-definition "${role_def}" -o none || warn "Usage role update failed — see error above"
  else
    run az role definition create --role-definition "${role_def}" -o none || { warn "Usage role create failed — see error above"; return 0; }
  fi

  log "Phase 2.6 — Assigning '${role_name}' to LumiTure SP (custom roles can take ~1m to propagate)…"
  local i
  for i in 1 2 3 4 5 6; do
    if run az role assignment create \
        --assignee-object-id "${SP_OBJECT_ID}" \
        --assignee-principal-type ServicePrincipal \
        --role "${role_name}" \
        --scope "${scope}" \
        -o none 2>/dev/null; then
      ok "Usage custom role assigned to LumiTure SP"
      return 0
    fi
    [[ "${DRY_RUN}" -eq 1 ]] && { ok "DRY-RUN: usage role assignment"; return 0; }
    warn "  role not yet propagated (attempt ${i}/6) — retrying in 15s…"
    sleep 15
  done
  warn "Usage role assignment did not succeed after retries — re-run, or assign '${role_name}' to the SP in the portal."
}

# -----------------------------------------------------------------------------
# Phase 2.7 — Event Grid subscription (billing DATA path)
# The customer-side export lands in the customer's storage; LumiTure ingests it
# into its own managed storage via an Azure Function (the event-trigger URL). That
# function is invoked by an Event Grid subscription on the storage account that
# fires on BlobCreated → webhook. WITHOUT this, billing cost data never reaches
# LumiTure. Params mirror the in-product wizard's "SetUp Data Access — Step 2".
# -----------------------------------------------------------------------------

resolve_event_trigger_url() {
  [[ -n "${EVENT_TRIGGER_URL}" ]] && { printf '%s' "${EVENT_TRIGGER_URL}"; return 0; }
  # Fetch from the LumiTure API if we have a token (env-specific Function URL).
  if [[ -n "${LUMITURE_API}" && -n "${LUMITURE_JWT}" ]]; then
    curl -s -H "Authorization: Bearer ${LUMITURE_JWT}" \
      "${LUMITURE_API}/platforms/azure/authorization/event-trigger-url/" \
      | jq -r '.data.url // empty' 2>/dev/null
  fi
}

setup_event_subscription() {
  local url
  url=$(resolve_event_trigger_url)
  if [[ -z "${url}" ]]; then
    warn "Phase 2.7 — no event-trigger URL (pass --event-trigger-url, or --lumiture-api + --lumiture-jwt to fetch it)."
    warn "  Skipping the Event Grid subscription — billing DATA will NOT flow until it's created."
    return 0
  fi

  # Provider registration is async — MUST complete before event-subscription create,
  # or the create fails with "Microsoft.EventGrid is not registered". --wait blocks
  # until Registered (no-op/fast if already registered).
  log "Phase 2.7 — Registering Microsoft.EventGrid provider (waiting for completion, can take ~1-2 min)…"
  run az provider register --namespace Microsoft.EventGrid --wait -o none

  log "Phase 2.7 — Creating Event Grid subscription '${EVENT_SUB_NAME}' (BlobCreated → LumiTure webhook) on ${STORAGE_ACCOUNT}…"
  if run az eventgrid event-subscription create \
      --name "${EVENT_SUB_NAME}" \
      --source-resource-id "${STORAGE_ACCOUNT_ID}" \
      --included-event-types Microsoft.Storage.BlobCreated \
      --endpoint-type webhook \
      --endpoint "${url}" \
      -o none; then
    ok "Event subscription created → billing data flows to LumiTure on the next export run"
  else
    warn "Event subscription create failed — see the az error above."
    warn "  The endpoint must be reachable and pass Event Grid's validation handshake."
    warn "  (It will NOT validate against a placeholder URL — pass the real"
    warn "  event-trigger URL provided by LumiTure.)"
  fi
}

# -----------------------------------------------------------------------------
# Phase 3 — Output / Submit
# -----------------------------------------------------------------------------

emit_form_values() {
  log "Phase 3 — Form values ready for the LumiTure Azure wizard or API:"
  cat <<EOF
{
  "tenant_id": "${TENANT_ID}",
  "subscription_id": "${SUBSCRIPTION_ID}",
  "storage_account": "${STORAGE_ACCOUNT}",
  "container": "${CONTAINER}"
}
EOF
}

submit_to_lumiture() {
  [[ -n "${LUMITURE_API}" ]] || { log "Skipping auto-submit (no --lumiture-api set)"; return 0; }
  [[ -n "${LUMITURE_JWT}" ]] || { ok "Grants done. No --lumiture-jwt → skipping auto-submit; enter the values above in the wizard to finish."; return 0; }

  log "Phase 3.s — Submitting to ${LUMITURE_API}/platforms/azure/authorization/admin-consent-url…"
  # Because the SP is already consented, this endpoint returns 200 and creates
  # the AzureSubscription directly (no second browser redirect needed).
  local payload
  payload=$(cat <<EOF
{"tenant_id": "${TENANT_ID}", "subscription_id": "${SUBSCRIPTION_ID}"}
EOF
)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: would POST ${LUMITURE_API}/platforms/azure/authorization/admin-consent-url"
    return 0
  fi

  local http_status
  http_status=$(curl -s -o /tmp/lumiture-azure-submit.out -w '%{http_code}' \
    -X POST "${LUMITURE_API}/platforms/azure/authorization/admin-consent-url" \
    -H "Authorization: Bearer ${LUMITURE_JWT}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
    ok "LumiTure Azure subscription registered (HTTP ${http_status})"
    cat /tmp/lumiture-azure-submit.out >&2
  else
    err "LumiTure submit failed: HTTP ${http_status}"
    cat /tmp/lumiture-azure-submit.out >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Main flow
# -----------------------------------------------------------------------------

main() {
  preflight
  verify_sp_consented

  if [[ "${DISCOVER_ONLY}" -eq 1 ]]; then
    log "--discover-only mode — SP consent confirmed, emitting values, exiting before grant/export/submit"
    emit_form_values
    exit 0
  fi

  ensure_storage
  grant_cost_reader
  grant_blob_reader
  validate_grants

  if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
    create_export "${EXPORT_NAME}" "ActualCost" "daily-actual-cost"
    [[ "${WITH_FOCUS}" -eq 1 ]] && create_export "daily-focus-cost" "FocusCost" "daily-focus-cost"
    # The export only matters if its blobs reach LumiTure — wire the Event Grid subscription.
    [[ "${SKIP_EVENT_SUBSCRIPTION}" -eq 0 ]] && setup_event_subscription
  else
    log "--skip-export set — grants applied, no Cost Management export created"
  fi

  [[ "${WITH_USAGE}" -eq 1 ]] && grant_usage_role

  emit_form_values
  submit_to_lumiture
  ok "Azure onboarding complete"
}

main "$@"
