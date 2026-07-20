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
#   init.sh [options]
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
#   --export-retention-days <n>         auto-delete export blobs older than n days (default 180,
#                                       keeps storage cost flat + bounds blob accumulation)
#   --no-retention                      do not set the lifecycle rule (keep every export blob)
#   --with-focus                        create a FOCUS-format export (daily-focus-cost) — ON by default
#   --no-focus                          skip the FOCUS export (billing/ActualCost only)
#   --with-usage                        create+assign the usage custom role (VM + Monitor metrics
#                                       read) for rightsizing/usage data — ON by default (full FinOps)
#   --no-usage                          skip the usage role (minimal, billing-only grant)
#   --backfill-months   <n>             seed n months of HISTORY as one-time exports (default 3,
#                                       matching GCP's first-connect backfill). 0 disables.
#                                       Only the shell can do this — it runs as you (Owner);
#                                       LumiTure's own service principal is read-only and
#                                       cannot create exports.
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
readonly LUMITURE_WIZARD_URL="https://app.lumiture.ai/authorization/billing-integration/azure"
readonly ROLE_COST_READER="Cost Management Reader"
readonly ROLE_BLOB_READER="Storage Blob Data Reader"
# Blob Data Contributor (write) — needed by a new-generation export's OWN managed
# identity when the destination storage disallows shared-key access. See create_export.
readonly ROLE_BLOB_CONTRIBUTOR="Storage Blob Data Contributor"

# Non-fatal failures accumulate here; the final Phase 4 self-check reports them and
# exits non-zero, so a partially-broken onboarding never masquerades as complete.
FAILURES=()
fail() { FAILURES+=("$1"); err "$1"; }

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
RETENTION_DAYS=180
WITH_FOCUS=1
WITH_USAGE=1
BACKFILL_MONTHS=3
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
    --export-retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    --no-retention) RETENTION_DAYS=0; shift ;;
    --with-focus) WITH_FOCUS=1; shift ;;
    --no-focus) WITH_FOCUS=0; shift ;;
    --with-usage) WITH_USAGE=1; shift ;;
    --no-usage) WITH_USAGE=0; shift ;;
    --backfill-months) BACKFILL_MONTHS="$2"; shift 2 ;;
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

# Validate before any arithmetic test reads it — `-gt` on a non-number aborts mid-run
# instead of pointing at the argument that was actually wrong.
[[ "${BACKFILL_MONTHS}" =~ ^[0-9]+$ ]] \
  || die "--backfill-months must be a non-negative integer (got '${BACKFILL_MONTHS}')"

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

  # Default the export destination from the subscription (POC parity) so bare `./init.sh` works;
  # pass --storage-account / --storage-rg to override.
  STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-ltexp$(printf '%s' "${SUBSCRIPTION_ID}" | tr -d '-' | cut -c1-15)}"
  STORAGE_RG="${STORAGE_RG:-lumiture-billing-rg}"

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

  # Lifecycle rule: the exports never de-duplicate (each daily run drops a fresh
  # full-month cumulative CSV), so the container would grow unbounded. LumiTure's
  # function copies each blob on creation, so the customer-side copy is only a
  # landing zone — auto-delete blobs older than RETENTION_DAYS to keep cost flat.
  if [[ "${RETENTION_DAYS}" -gt 0 ]]; then
    log "Phase 1 — Setting a ${RETENTION_DAYS}-day lifecycle rule on ${CONTAINER}/cost (auto-delete old export blobs)…"
    local policy
    policy="{\"rules\":[{\"enabled\":true,\"name\":\"lumiture-export-retention\",\"type\":\"Lifecycle\",\"definition\":{\"filters\":{\"blobTypes\":[\"blockBlob\"],\"prefixMatch\":[\"${CONTAINER}/cost/\"]},\"actions\":{\"baseBlob\":{\"delete\":{\"daysAfterModificationGreaterThan\":${RETENTION_DAYS}}}}}}]}"
    if run az storage account management-policy create --account-name "${STORAGE_ACCOUNT}" -g "${STORAGE_RG}" --policy "${policy}" -o none; then
      ok "Lifecycle rule applied (export blobs deleted after ${RETENTION_DAYS} days)"
    else
      warn "Could not set the lifecycle rule — see the az error above (non-fatal; storage still works)."
    fi
  fi

  # --wait, or the first export create in Phase 2.5 races the async registration and
  # 503s ("RP registration in progress") — which historically produced a FOCUS-only
  # onboarding. --wait is a fast no-op once the RP is already registered (the common
  # case on re-runs), matching how Phase 2.7 handles the EventGrid provider.
  log "Phase 1 — Registering Microsoft.CostManagementExports provider (waiting for completion, can take ~1-2 min)…"
  run az provider register --namespace Microsoft.CostManagementExports --wait -o none
  ok "Provider registered"
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
    grant_export_identity "${name}" "${api_version}"
  else
    fail "Export '${name}' create failed — see the az error above."
  fi
}

# -----------------------------------------------------------------------------
# Grant a new-generation export's OWN managed identity write access to the storage.
#
# Cost Management writes the export blob using the export's identity. When the
# destination storage allows shared-key access, the export uses the account key,
# gets identity=null, and needs no grant. When shared-key access is DISABLED
# (common under CSP / enterprise security policy), Azure attaches a system-assigned
# managed identity to the export and authenticates with AAD — and that identity
# needs "Storage Blob Data Contributor" or every run fails, silently, with
# `AccessToStorageAccountDenied`. init.sh runs as the customer (Owner) here, so it
# can grant it; LumiTure's own read-only SP cannot. Idempotent.
# -----------------------------------------------------------------------------
grant_export_identity() {
  local name="$1" api_version="$2"
  [[ "${DRY_RUN}" -eq 1 ]] && { log "  DRY-RUN: would check/grant export '${name}' managed identity"; return 0; }

  local url mi
  url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/exports/${name}?api-version=${api_version}"
  mi=$(az rest --method GET --url "${url}" \
        --query "identity.principalId" -o tsv 2>/dev/null || true)

  if [[ -z "${mi}" || "${mi}" == "None" ]]; then
    log "  Export '${name}' writes via shared key (no managed identity) — no extra grant needed."
    return 0
  fi

  log "  Export '${name}' uses a managed identity (${mi:0:8}…) — storage disallows shared key; granting '${ROLE_BLOB_CONTRIBUTOR}'…"
  if az role assignment create \
       --assignee-object-id "${mi}" \
       --assignee-principal-type ServicePrincipal \
       --role "${ROLE_BLOB_CONTRIBUTOR}" \
       --scope "${STORAGE_ACCOUNT_ID}" -o none 2>/dev/null; then
    ok "  Export '${name}' managed identity granted write on ${STORAGE_ACCOUNT}"
  else
    # A prior identical assignment returns non-zero on some az builds; treat an
    # already-present grant as success, otherwise record a real failure.
    if az role assignment list --assignee "${mi}" --scope "${STORAGE_ACCOUNT_ID}" \
         --query "[?roleDefinitionName=='${ROLE_BLOB_CONTRIBUTOR}'] | length(@)" -o tsv 2>/dev/null \
         | grep -q '^[1-9]'; then
      ok "  Export '${name}' managed identity already had write on ${STORAGE_ACCOUNT}"
    else
      fail "Export '${name}' managed identity could NOT be granted '${ROLE_BLOB_CONTRIBUTOR}' on ${STORAGE_ACCOUNT} — FOCUS/this export will produce no data until it is."
    fi
  fi
}

# -----------------------------------------------------------------------------
# Phase 2.55 — Historical backfill (one-time Custom exports)
#
# Azure captures only the CURRENT month on first connect; GCP backfills 3. The gap
# can only be closed from here: LumiTure's service principal is read-only on the
# customer subscription (Microsoft.CostManagement/*/read — an export PUT returns 401),
# so no backend job can seed history. This shell runs as the customer (Owner) and can.
#
# One export per month, per Microsoft's documented seed pattern ("no more than one
# month's of data per report"). Each month needs its OWN export name because the
# LumiTure copy-function keys the "latest run" on the source prefix — sharing one
# prefix would collapse every month into the newest run. Names follow
# <canonical-subfolder>-backfill-<YYYYMM> so the function can route each blob back to
# the canonical destination subfolder the transfer already reads.
#
# Rooted at "backfill" (not "cost") so a one-time historical export can never be
# mistaken for the live recurring one.
# -----------------------------------------------------------------------------

# Echoes "<YYYYMM> <first-day> <last-day>" for the month N months before this one.
month_bounds() {
  local back="$1" prev first last
  prev=$(( back - 1 ))
  # GNU date (Cloud Shell) first, BSD/macOS fallback. The last day is derived as
  # "first of the following month, minus a day" so month lengths and leap years
  # never have to be special-cased.
  first=$(date -u -d "$(date -u +%Y-%m-01) -${back} month" +%Y-%m-01 2>/dev/null \
          || date -u -v1d -v-"${back}"m +%Y-%m-01)
  last=$(date -u -d "$(date -u +%Y-%m-01) -${prev} month -1 day" +%Y-%m-%d 2>/dev/null \
         || date -u -v1d -v-"${prev}"m -v-1d +%Y-%m-%d)
  printf '%s %s %s' "${first:0:4}${first:5:2}" "${first}" "${last}"
}

create_backfill_export() {
  local subfolder="$1" export_type="$2" yyyymm="$3" first="$4" last="$5"
  local name="${subfolder}-backfill-${yyyymm}"

  local api_version dataset
  if [[ "${export_type}" == "FocusCost" ]]; then
    api_version="2023-07-01-preview"
    dataset='"granularity": "Daily", "configuration": { "dataVersion": "1.0" }'
  else
    api_version="2023-11-01"
    dataset='"granularity": "Daily"'
  fi

  log "Phase 2.55 — Backfilling ${export_type} for ${first:0:7} as '${name}'…"
  local url body
  url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/exports/${name}?api-version=${api_version}"
  # One-time export: schedule Inactive (no recurrence), Custom timeframe, and
  # partitionData:true — Azure rejects a custom-timeframe export without it.
  body="{\"properties\":{\"schedule\":{\"status\":\"Inactive\"},\"format\":\"Csv\",\"partitionData\":true,\"deliveryInfo\":{\"destination\":{\"resourceId\":\"${STORAGE_ACCOUNT_ID}\",\"container\":\"${CONTAINER}\",\"rootFolderPath\":\"backfill\"}},\"definition\":{\"type\":\"${export_type}\",\"timeframe\":\"Custom\",\"timePeriod\":{\"from\":\"${first}T00:00:00Z\",\"to\":\"${last}T23:59:59Z\"},\"dataSet\":{${dataset}}}}}"

  if ! run az rest --method PUT --url "${url}" --headers "Content-Type=application/json" --body "${body}" -o none; then
    fail "Backfill export '${name}' create failed — ${first:0:7} history will be missing."
    return 1
  fi

  grant_export_identity "${name}" "${api_version}"

  # A one-time export never fires on its own — it has no recurrence, so it must be
  # executed explicitly or it produces nothing at all.
  [[ "${DRY_RUN}" -eq 1 ]] && { ok "  DRY-RUN: would run backfill export '${name}'"; return 0; }
  if run az rest --method POST \
       --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/exports/${name}/run?api-version=${api_version}" \
       -o none; then
    ok "  Backfill '${name}' queued (${first} → ${last})"
  else
    fail "Backfill export '${name}' was created but could not be executed — no ${first:0:7} data will be produced."
  fi
}

create_backfill_exports() {
  log "Phase 2.55 — Seeding ${BACKFILL_MONTHS} month(s) of history (one one-time export per month)…"

  local i yyyymm first last
  for (( i = 1; i <= BACKFILL_MONTHS; i++ )); do
    # Start at 1, not 0: the current month is already covered by the recurring
    # MonthToDate export, and a second writer for it would fight over the same
    # destination folder.
    read -r yyyymm first last <<<"$(month_bounds "${i}")"
    create_backfill_export "daily-actual-cost" "ActualCost" "${yyyymm}" "${first}" "${last}"
    [[ "${WITH_FOCUS}" -eq 1 ]] && \
      create_backfill_export "daily-focus-cost" "FocusCost" "${yyyymm}" "${first}" "${last}"
  done
  log "  Backfilled months are produced by Azure over the next hours; they appear in"
  log "  LumiTure after the next ingestion cycle — not immediately."
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
# Phase 4 — Structural self-check (independent read-back)
#
# The shell can't confirm DATA at onboarding time — exports are dated +1 day and
# nothing has run yet. But every failure that leaves an onboarding silently
# dead is STRUCTURAL and checkable now: a missing export (RP-registration race),
# an export pointing at the wrong storage (name typo / generation twin), an
# ungranted export managed identity, or an Event Grid subscription aimed at the
# wrong endpoint. Read the live state back and record anything wrong into
# FAILURES so main() can exit non-zero instead of printing a green "complete".
# -----------------------------------------------------------------------------
verify_onboarding() {
  [[ "${SKIP_EXPORT}" -eq 1 ]] && { log "Phase 4 — --skip-export set, nothing to verify."; return 0; }
  [[ "${DRY_RUN}" -eq 1 ]] && { log "Phase 4 — DRY-RUN, skipping verification."; return 0; }
  log "Phase 4 — Verifying the onboarding is structurally complete (data still lands ~1 day later)…"

  local exports_json
  exports_json=$(az rest --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/exports?api-version=2023-07-01-preview" \
    2>/dev/null || echo '{"value":[]}')

  # Required export names → check one exists AND lands on OUR storage account.
  local required=("daily-actual-cost")
  [[ "${WITH_FOCUS}" -eq 1 ]] && required+=("daily-focus-cost")
  local name
  for name in "${required[@]}"; do
    local on_ours
    on_ours=$(printf '%s' "${exports_json}" | jq -r --arg n "${name}" --arg sa "${STORAGE_ACCOUNT}" \
      '[.value[] | select(.name==$n) | select((.properties.deliveryInfo.destination.resourceId // "") | endswith("/"+$sa))] | length')
    if [[ "${on_ours}" -ge 1 ]]; then
      ok "  ✓ export '${name}' exists and targets ${STORAGE_ACCOUNT}"
      # Any same-named export pointing ELSEWHERE is a generation twin → data split.
      local elsewhere
      elsewhere=$(printf '%s' "${exports_json}" | jq -r --arg n "${name}" --arg sa "${STORAGE_ACCOUNT}" \
        '[.value[] | select(.name==$n) | select((.properties.deliveryInfo.destination.resourceId // "") | endswith("/"+$sa) | not)] | length')
      [[ "${elsewhere}" -ge 1 ]] && warn "    ⚠ a second '${name}' export points at a DIFFERENT storage account (generation twin) — delete it in the Portal (delete-by-name hits the wrong one)."
    else
      fail "Export '${name}' is missing or points at the wrong storage — no data will flow. (First create can 503 on RP registration; re-run.)"
    fi

    # Each export using a managed identity must have write on the storage.
    local mi
    mi=$(printf '%s' "${exports_json}" | jq -r --arg n "${name}" --arg sa "${STORAGE_ACCOUNT}" \
      'first(.value[] | select(.name==$n) | select((.properties.deliveryInfo.destination.resourceId // "") | endswith("/"+$sa)) | .identity.principalId) // empty')
    if [[ -n "${mi}" && "${mi}" != "null" ]]; then
      if az role assignment list --assignee "${mi}" --scope "${STORAGE_ACCOUNT_ID}" \
           --query "[?roleDefinitionName=='${ROLE_BLOB_CONTRIBUTOR}'] | length(@)" -o tsv 2>/dev/null \
           | grep -q '^[1-9]'; then
        ok "  ✓ export '${name}' managed identity has write on storage"
      else
        fail "Export '${name}' managed identity lacks '${ROLE_BLOB_CONTRIBUTOR}' on ${STORAGE_ACCOUNT} — its runs will fail (AccessToStorageAccountDenied) and no data flows."
      fi
    fi
  done

  # Backfill exports: one per month per type, all on OUR storage. A missing one is a
  # silently absent month of history, indistinguishable later from "the customer had
  # no spend then".
  if [[ "${BACKFILL_MONTHS}" -gt 0 ]]; then
    local types=("daily-actual-cost")
    [[ "${WITH_FOCUS}" -eq 1 ]] && types+=("daily-focus-cost")
    local i yyyymm first last t bname present
    for (( i = 1; i <= BACKFILL_MONTHS; i++ )); do
      read -r yyyymm first last <<<"$(month_bounds "${i}")"
      for t in "${types[@]}"; do
        bname="${t}-backfill-${yyyymm}"
        present=$(printf '%s' "${exports_json}" | jq -r --arg n "${bname}" --arg sa "${STORAGE_ACCOUNT}" \
          '[.value[] | select(.name==$n) | select((.properties.deliveryInfo.destination.resourceId // "") | endswith("/"+$sa))] | length')
        if [[ "${present}" -ge 1 ]]; then
          ok "  ✓ backfill export '${bname}' exists"
        else
          fail "Backfill export '${bname}' is missing — ${first:0:7} history will never arrive."
        fi
      done
    done
  fi

  # Event Grid: a subscription must exist AND point at the URL we were given.
  if [[ "${SKIP_EVENT_SUBSCRIPTION}" -eq 0 ]]; then
    local eg_dest
    eg_dest=$(az eventgrid event-subscription list --source-resource-id "${STORAGE_ACCOUNT_ID}" \
      --query "[?name=='${EVENT_SUB_NAME}'].destination.endpointBaseUrl | [0]" -o tsv 2>/dev/null || true)
    if [[ -z "${eg_dest}" ]]; then
      fail "Event Grid subscription '${EVENT_SUB_NAME}' is missing — blobs will never reach LumiTure."
    elif [[ -n "${EVENT_TRIGGER_URL}" && "${eg_dest}" != "${EVENT_TRIGGER_URL}" ]]; then
      fail "Event Grid subscription points at ${eg_dest} but the expected trigger is ${EVENT_TRIGGER_URL} — data would flow to the wrong environment (this is SILENT in Azure)."
    else
      ok "  ✓ Event Grid subscription targets the expected trigger URL"
    fi
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
    # Strictly AFTER Event Grid: a backfill export runs within minutes, so wiring the
    # subscription later would let the historical blobs land with nothing listening —
    # they are one-time runs, so nothing would ever re-deliver them.
    [[ "${BACKFILL_MONTHS}" -gt 0 ]] && create_backfill_exports
  else
    log "--skip-export set — grants applied, no Cost Management export created"
  fi

  [[ "${WITH_USAGE}" -eq 1 ]] && grant_usage_role

  verify_onboarding

  emit_form_values
  submit_to_lumiture

  # Never claim success we didn't verify. A failed export/grant only warned above;
  # here it becomes a non-zero exit with a named summary, so a half-broken
  # onboarding (FOCUS-only, ungranted MI, misrouted export) can't read as complete.
  if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    err "Azure onboarding INCOMPLETE — ${#FAILURES[@]} problem(s):"
    for f in "${FAILURES[@]}"; do err "  • ${f}"; done
    err "Fix the above and re-run. Data will NOT flow until every item is resolved."
    exit 1
  fi
  ok "Azure onboarding complete — structure verified. Cost data lands in ~1 day (first export run + ingestion); confirm tomorrow, not today."
}

main "$@"
