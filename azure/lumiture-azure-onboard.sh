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
#   --container         <name>          default: billing-exports
#   --export-name       <name>          default: lumiture-daily-actual-cost
#   --with-focus                        also create a FOCUS-format export (daily-focus-cost)
#   --with-usage                        also create+assign the usage custom role (VM + Monitor
#                                       metrics read) for rightsizing/usage data — billing alone
#                                       does not need it; opt in for full FinOps
#   --lumiture-app-id   <GUID>          default: prod LumiTure multi-tenant SP app id
#   --lumiture-api      <https://api.lumiture.ai>   for auto-submit; omit to skip submit
#   --lumiture-jwt      <token>         provide to auto-submit; omit to finish in the wizard
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

# TODO(fill-in): replace with LumiTure's PROD Azure multi-tenant SP App (client) ID.
# Pull from the in-product Azure wizard, or from prod config (the same client id
# used to build the admin-consent URL). Kept as a placeholder so the POC stays
# free of any assumed credential.
readonly LUMITURE_APP_ID_PROD="REPLACE_WITH_LUMITURE_AZURE_APP_ID"
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
CONTAINER="billing-exports"
EXPORT_NAME="lumiture-daily-actual-cost"
WITH_FOCUS=0
WITH_USAGE=0
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
# LumiTure's pipeline reads {tenant_id}/{subscription_id}/{YYYYMM}/daily-actual-cost/
# (and daily-focus-cost/ for FOCUS). We root the export at <tenant>/<subscription>.
# -----------------------------------------------------------------------------

create_export() {
  local name="$1" export_type="$2" subdir="$3"
  # az costmanagement export create REQUIRES --recurrence-period when --recurrence is set,
  # and the start date must be in the future. GNU date (Cloud Shell) first, BSD/macOS fallback.
  local from_date to_date
  from_date=$(date -u -d '+1 day' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v+1d +%Y-%m-%dT00:00:00Z)
  to_date=$(date -u -d '+5 years' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v+5y +%Y-%m-%dT00:00:00Z)
  log "Phase 2.5 — Creating ${export_type} export '${name}' → ${STORAGE_ACCOUNT}/${CONTAINER}/${TENANT_ID}/${SUBSCRIPTION_ID}/${subdir} (daily ${from_date}…${to_date})…"
  if run az costmanagement export create \
    --name "${name}" \
    --type "${export_type}" \
    --scope "subscriptions/${SUBSCRIPTION_ID}" \
    --storage-account-id "${STORAGE_ACCOUNT_ID}" \
    --storage-container "${CONTAINER}" \
    --storage-directory "${TENANT_ID}/${SUBSCRIPTION_ID}/${subdir}" \
    --timeframe MonthToDate \
    --recurrence Daily \
    --recurrence-period from="${from_date}" to="${to_date}" \
    --schedule-status Active \
    -o none; then
    ok "Export '${name}' configured (first run lands within ~24h)"
  else
    warn "Export '${name}' create failed — see the az error above. (FOCUS export may need a newer az / portal step.)"
  fi
}

# -----------------------------------------------------------------------------
# Phase 2.6 — Usage custom role (opt-in: --with-usage)
# Usage/rightsizing data needs the SP to read VMs + Azure Monitor metrics, which
# Cost Management Reader does NOT cover. LumiTure defines a custom role for this
# (backend: AzureAuthorizationService.get_usage_custom_role); we create + assign it.
# The role name is cosmetic for the customer; the LumiTure usage-check validates by
# listing VMs, so what matters is the action set below matching the backend.
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
    [[ "${WITH_FOCUS}" -eq 1 ]] && create_export "lumiture-daily-focus-cost" "FocusCost" "daily-focus-cost"
  else
    log "--skip-export set — grants applied, no Cost Management export created"
  fi

  [[ "${WITH_USAGE}" -eq 1 ]] && grant_usage_role

  emit_form_values
  submit_to_lumiture
  ok "Azure onboarding complete"
}

main "$@"
