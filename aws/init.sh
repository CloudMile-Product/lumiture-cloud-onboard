#!/usr/bin/env bash
# LumiTure AWS Onboarding — automated billing-data integration
#
# Automates the customer-side setup for the AWS billing integration:
#   1. Confirm this is the Organization MANAGEMENT (or a standalone) account
#   2. Check bcm-data-exports quota headroom (LumiTure creates 1 CUR + 1 FOCUS export)
#   3. Create the customer-managed IAM policy LumiTure requires (exact document)
#   4. Create the cross-account IAM role trusting LumiTure (+ ExternalId), attach the policy
#   5. (Optional, --with-usage) Deploy the member-account monitoring StackSet
#   6. Collect form values
#   7. (Optional) Submit to LumiTure
#
# Unlike the GCP/Azure flows, the customer does NOT provision the data pipeline:
# LumiTure's backend assumes the role created here and creates the S3 buckets +
# billing exports itself. That is why the policy below is not purely read-only —
# it allows S3 writes, but ONLY on the two dedicated lumiture-<account>-cur/-focus
# buckets, plus billing-export management. Nothing touches your workloads.
#
# Usage:
#   init.sh [options]
#
# Optional (everything defaults for production):
#   --role-name         <name>   IAM role to create (default: LumiTureIntegrationRole)
#   --policy-name       <name>   IAM policy to create (default: LumiTureIntegrationPolicy)
#   --external-id       <id>     ExternalId for the role trust. Default: reuse the one
#                                already on the role (re-runs), else fetch from the
#                                LumiTure API (with --lumiture-jwt), else generate locally.
#   --with-usage                 ALSO deploy the CloudFormation StackSet that creates a
#                                read-only monitoring role in EVERY member account
#                                (rightsizing/usage data). Off by default: it flips on
#                                org-wide StackSets trusted access — larger blast radius
#                                than the billing role. Requires an AWS Organization.
#   --stackset-name     <name>   default: LumiTureAccountMemberMonitoringSet
#   --member-role-name  <name>   default: LumiTureAccountMemberMonitoringRole
#   --usage-external-id <id>     ExternalId for the member roles (SEPARATE from the
#                                billing one). Default: generated locally.
#   --ou-ids            <id,..>  StackSet deployment targets (default: the org root —
#                                every account). Comma-separated OU ids to narrow.
#   --lumiture-api      <https://api.lumiture.ai>   for auto-submit; omit to skip submit
#   --lumiture-jwt      <token>  provide to auto-submit; omit to finish in the wizard
#   --discover-only     run discovery + report only; no create, no submit
#   --dry-run           print commands without executing
#   --verbose           set -x
#   --help              print this and exit

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants — LumiTure's AWS account each customer's role trusts. The account ID
# is public by design (also shown in the in-product wizard), analogous to the
# GCP service-account email and the Azure multi-tenant App ID. NOT a secret.
# -----------------------------------------------------------------------------

readonly LUMITURE_AWS_ACCOUNT_ID="536697256548"
readonly LUMITURE_PRINCIPAL_ARN="arn:aws:iam::${LUMITURE_AWS_ACCOUNT_ID}:root"
readonly LUMITURE_API_PROD="https://api.lumiture.ai"
readonly LUMITURE_WIZARD_URL="https://app.lumiture.ai/authorization/billing-integration/aws"
readonly LUMITURE_USAGE_WIZARD_URL="https://app.lumiture.ai/authorization/usage-integration/aws"
# The StackSet template is validated server-side against THIS hosted copy
# (byte-compared) — always deploy by URL, never from a local file.
readonly STACKSET_TEMPLATE_URL="https://lumiture-stackset-template.s3.us-east-1.amazonaws.com/member_role_template.yaml"
# Billing exports, their buckets and the StackSets API all live in us-east-1
# (IAM / STS / Organizations are global). Pinned; the CloudShell region doesn't matter.
readonly AWS_REGION="us-east-1"
# LumiTure creates 1 CUR + 1 FOCUS export in this account; AWS caps them at 5 / 2.
readonly CUR_LIMIT=5
readonly FOCUS_LIMIT=2

# Non-fatal failures accumulate here; the final Phase 5 self-check reports them and
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

ROLE_NAME="LumiTureIntegrationRole"
POLICY_NAME="LumiTureIntegrationPolicy"
EXTERNAL_ID=""
EXTERNAL_ID_EXPLICIT=0
WITH_USAGE=0
STACKSET_NAME="LumiTureAccountMemberMonitoringSet"
MEMBER_ROLE_NAME="LumiTureAccountMemberMonitoringRole"
USAGE_EXTERNAL_ID=""
OU_IDS=""
LUMITURE_API=""
LUMITURE_JWT=""
DISCOVER_ONLY=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    --policy-name) POLICY_NAME="$2"; shift 2 ;;
    --external-id) EXTERNAL_ID="$2"; EXTERNAL_ID_EXPLICIT=1; shift 2 ;;
    --with-usage) WITH_USAGE=1; shift ;;
    --stackset-name) STACKSET_NAME="$2"; shift 2 ;;
    --member-role-name) MEMBER_ROLE_NAME="$2"; shift 2 ;;
    --usage-external-id) USAGE_EXTERNAL_ID="$2"; shift 2 ;;
    --ou-ids) OU_IDS="$2"; shift 2 ;;
    --lumiture-api) LUMITURE_API="$2"; shift 2 ;;
    --lumiture-jwt) LUMITURE_JWT="$2"; shift 2 ;;
    --discover-only) DISCOVER_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) set -x; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 — try --help" ;;
  esac
done

# Defaults target LumiTure production; override with --lumiture-api if needed.
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

# Trim leading/trailing whitespace of a whole (possibly multi-line) string —
# mirrors the server-side .strip() used to compare the StackSet template body.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# 12-char alphanumeric, the same shape LumiTure's own generator produces.
# (dd a fixed block first so tr/cut never die on SIGPIPE under pipefail.)
gen_external_id() { dd if=/dev/urandom bs=256 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-12; }

# -----------------------------------------------------------------------------
# The IAM policy LumiTure validates — EXACT-MATCH CONTRACT
#
# LumiTure's permission check compares this document to the live policy with
# strict equality, not a superset check. Every action, the statement order, and
# even "Resource" being a string ("*") vs a one-element list (["*"]) must match
# what the backend expects. Do not "clean up" the inconsistencies below — they
# mirror the server-side document verbatim.
# -----------------------------------------------------------------------------

expected_policy_json() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:GetObject",
        "s3:CreateBucket",
        "s3:PutBucketPolicy",
        "s3:PutBucketNotification",
        "s3:GetBucketNotification"
      ],
      "Resource": [
        "arn:aws:s3:::lumiture-${ACCOUNT_ID}-cur",
        "arn:aws:s3:::lumiture-${ACCOUNT_ID}-focus"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "bcm-data-exports:CreateExport",
        "bcm-data-exports:ListExports",
        "bcm-data-exports:GetExport",
        "bcm-data-exports:DeleteExport",
        "bcm-data-exports:UpdateExport",
        "cur:PutReportDefinition",
        "cur:DeleteReportDefinition",
        "cur:ModifyReportDefinition",
        "cur:DescribeReportDefinitions"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "organizations:ListAccounts",
        "iam:ListAttachedRolePolicies",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListAccountAliases",
        "account:GetAccountInformation"
      ],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:DescribeStackInstance",
        "cloudformation:DescribeStackSet",
        "cloudformation:DescribeStacks",
        "cloudformation:ListStackInstances",
        "cloudformation:ListStackSets",
        "cloudformation:ListStacks",
        "cloudformation:UpdateStackSet",
        "cloudwatch:Describe*",
        "cloudwatch:Get*",
        "cloudwatch:List*",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

trust_policy_json() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "${LUMITURE_PRINCIPAL_ARN}" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:ExternalId": "${EXTERNAL_ID}" } }
    }
  ]
}
EOF
}

# Returns 0 when the live default policy version equals the expected document.
# jq -S sorts object keys (equality ignores key order, like the server check)
# but preserves list order and string-vs-list shape (which the server check
# is sensitive to).
policy_doc_matches() {
  local vid live
  vid=$(aws iam get-policy --policy-arn "${POLICY_ARN}" --query Policy.DefaultVersionId --output text 2>/dev/null) || return 1
  live=$(aws iam get-policy-version --policy-arn "${POLICY_ARN}" --version-id "${vid}" \
           --query PolicyVersion.Document --output json 2>/dev/null) || return 1
  [[ "$(jq -S . <<<"${live}")" == "$(expected_policy_json | jq -S .)" ]]
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight() {
  log "Pre-flight checks…"

  command -v aws >/dev/null || die "AWS CLI not found — AWS CloudShell has it preinstalled"
  command -v jq >/dev/null || die "jq not found — install via 'brew install jq' / 'apt install jq'"
  aws --version 2>&1 | grep -q '^aws-cli/2' \
    || die "AWS CLI v2 required (v1 lacks the bcm-data-exports commands) — AWS CloudShell has v2"
  ok "Required tools installed (aws v2, jq)"

  local ident_json
  ident_json=$(aws sts get-caller-identity --output json 2>/dev/null) \
    || die "No AWS credentials — run this in AWS CloudShell, or configure the CLI first"
  ACCOUNT_ID=$(jq -r '.Account' <<<"${ident_json}")
  ok "Active AWS identity: $(jq -r '.Arn' <<<"${ident_json}") (account ${ACCOUNT_ID})"

  [[ "${ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || die "Could not resolve a 12-digit account id"

  # ARNs are deterministic — usable even before the resources exist (dry-run, discover).
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
}

# -----------------------------------------------------------------------------
# Phase 0 — Management-account gate
#
# Onboarding a MEMBER account as if it were the management account has
# historically destroyed billing data (the member's export displaced the
# management account's). LumiTure's backend also rejects it — refuse early,
# with a clear message. Standalone (no Organization) accounts are fine.
# Sets global: IS_ORG
# -----------------------------------------------------------------------------

check_management_account() {
  log "Phase 0 — Confirming this is the Organization management account…"
  local org_out
  if org_out=$(aws organizations describe-organization --output json 2>&1); then
    local mgmt
    mgmt=$(jq -r '.Organization.MasterAccountId' <<<"${org_out}")
    if [[ "${mgmt}" != "${ACCOUNT_ID}" ]]; then
      err "This is a MEMBER account of an AWS Organization (management account: ${mgmt})."
      err "Billing data for the whole Organization lives in the management (payer) account."
      die "Re-run this script from account ${mgmt} — onboarding a member account is refused."
    fi
    IS_ORG=1
    ok "Management account confirmed (org $(jq -r '.Organization.Id' <<<"${org_out}"))"
  elif grep -q 'AWSOrganizationsNotInUseException' <<<"${org_out}"; then
    IS_ORG=0
    warn "No AWS Organization — standalone account. Billing onboarding works; the usage StackSet does not apply."
  elif grep -q 'AccessDeniedException' <<<"${org_out}"; then
    # Only member accounts get AccessDenied on describe-organization when the
    # caller is an admin; management-account admins can always call it.
    err "organizations:DescribeOrganization was denied. If you are an admin, this usually"
    err "means you are in a MEMBER account (member accounts cannot read org details)."
    die "Run this from the Organization management (payer) account."
  else
    die "Could not determine the account's Organization role: ${org_out}"
  fi
}

# -----------------------------------------------------------------------------
# Phase 0.5 — Export quota headroom
#
# LumiTure will create 1 CUR 2.0 export + 1 FOCUS export in this account (it
# provisions them itself after assuming the role). AWS caps an account at
# 5 CUR / 2 FOCUS exports — if the account is already at the cap, LumiTure's
# permission check fails later with a quota error. Check now, loudly.
# -----------------------------------------------------------------------------

check_export_quota() {
  log "Phase 0.5 — Checking bcm-data-exports quota headroom (LumiTure adds 1 CUR + 1 FOCUS)…"
  local arns arn cur_count=0 focus_count=0
  # AWS CLI v2 auto-paginates list calls — no manual NextToken loop needed.
  if ! arns=$(aws bcm-data-exports list-exports --region "${AWS_REGION}" \
                --query 'Exports[].ExportArn' --output json 2>&1); then
    warn "Could not list existing exports (${arns})"
    warn "  Skipping the quota check — LumiTure's own permission check will still enforce it."
    return 0
  fi

  for arn in $(jq -r '.[]' <<<"${arns}"); do
    local table
    table=$(aws bcm-data-exports get-export --export-arn "${arn}" --region "${AWS_REGION}" \
              --query 'Export.DataQuery.TableConfigurations | keys(@) | [0]' --output text 2>/dev/null || true)
    case "${table}" in
      COST_AND_USAGE_REPORT) cur_count=$((cur_count + 1)) ;;
      FOCUS_1_0_AWS) focus_count=$((focus_count + 1)) ;;
    esac
  done

  log "  Existing exports: ${cur_count}/${CUR_LIMIT} CUR, ${focus_count}/${FOCUS_LIMIT} FOCUS"
  [[ "${cur_count}" -lt "${CUR_LIMIT}" ]] \
    || die "This account already has ${cur_count} CUR exports (AWS cap ${CUR_LIMIT}) — delete one or onboarding will fail at LumiTure's quota check."
  [[ "${focus_count}" -lt "${FOCUS_LIMIT}" ]] \
    || die "This account already has ${focus_count} FOCUS exports (AWS cap ${FOCUS_LIMIT}) — delete one or onboarding will fail at LumiTure's quota check."
  [[ "${cur_count}" -eq $((CUR_LIMIT - 1)) ]] && warn "  Only 1 CUR export slot left — LumiTure's export will take the last one."
  [[ "${focus_count}" -eq $((FOCUS_LIMIT - 1)) ]] && warn "  Only 1 FOCUS export slot left — LumiTure's export will take the last one."
  ok "Quota headroom confirmed"
}

# -----------------------------------------------------------------------------
# Phase 1 — External ID
# Precedence: --external-id > the value already on an existing role's trust
# (re-run safety — the previously submitted value stays valid) > fetch from the
# LumiTure API (JWT) > generate locally. Any 12-char alphanumeric works; the
# value only becomes binding when it is submitted with the form.
# -----------------------------------------------------------------------------

resolve_external_id() {
  log "Phase 1 — Resolving the ExternalId for the role trust…"

  if [[ "${EXTERNAL_ID_EXPLICIT}" -eq 1 ]]; then
    ok "Using the ExternalId passed via --external-id"
    return 0
  fi

  # Scan every trust statement for the one naming LumiTure's principal — the
  # LumiTure statement isn't guaranteed to be Statement[0] on a pre-existing
  # role. Reuse only an unambiguous (single distinct) ExternalId.
  local existing
  existing=$(aws iam get-role --role-name "${ROLE_NAME}" \
      --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null \
    | jq -r --arg p "${LUMITURE_PRINCIPAL_ARN}" \
        '[.Statement[]? | select((.Principal.AWS // empty) == $p)
          | .Condition.StringEquals."sts:ExternalId" // empty | select(. != "")]
         | unique | if length == 1 then .[0] else "" end' 2>/dev/null || true)
  if [[ -n "${existing}" ]]; then
    EXTERNAL_ID="${existing}"
    ok "Reusing the ExternalId already on role ${ROLE_NAME} (re-run detected; the value you may have already submitted stays valid)"
    return 0
  fi

  if [[ -n "${LUMITURE_JWT}" ]]; then
    EXTERNAL_ID=$(curl -s -H "Authorization: Bearer ${LUMITURE_JWT}" \
      "${LUMITURE_API}/platforms/aws/authorization/external-id/" \
      | jq -r '.data.external_id // .data.externalId // .external_id // empty' 2>/dev/null || true)
    if [[ -n "${EXTERNAL_ID}" ]]; then
      ok "Fetched a fresh ExternalId from the LumiTure API"
      return 0
    fi
    warn "Could not fetch an ExternalId from the API — generating one locally instead."
  fi

  EXTERNAL_ID=$(gen_external_id)
  ok "Generated ExternalId locally (same 12-char shape the wizard produces)"
}

# -----------------------------------------------------------------------------
# Phase 2 — Customer-managed policy (exact document, idempotent)
# -----------------------------------------------------------------------------

ensure_policy() {
  log "Phase 2 — Ensuring IAM policy ${POLICY_NAME} matches LumiTure's expected document…"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "$(expected_policy_json)"
    return 0
  fi

  local out
  if out=$(aws iam create-policy --policy-name "${POLICY_NAME}" \
             --description "LumiTure FinOps integration — billing-export management, restricted to the dedicated lumiture-* buckets" \
             --policy-document "$(expected_policy_json)" --output json 2>&1); then
    ok "Policy created: ${POLICY_ARN}"
    return 0
  fi

  grep -q 'EntityAlreadyExists' <<<"${out}" || die "Policy create failed: ${out}"

  log "  Policy ${POLICY_NAME} already exists — comparing its document…"
  if policy_doc_matches; then
    ok "Existing policy already matches the expected document (idempotent)"
    return 0
  fi

  warn "  Existing policy differs from the expected document — updating (new default version)…"
  # Managed policies hold at most 5 versions; prune the oldest non-default first.
  local nver
  nver=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" --query 'length(Versions)' --output text)
  if [[ "${nver}" -ge 5 ]]; then
    # Pick the oldest by CreateDate explicitly — the API doesn't promise the
    # list's ordering, and deleting the wrong version would drop a rollback point.
    local oldest
    oldest=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" --output json \
      | jq -r '[.Versions[] | select(.IsDefaultVersion | not)] | sort_by(.CreateDate) | first.VersionId')
    log "  At the 5-version cap — deleting oldest non-default version ${oldest}"
    run aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${oldest}"
  fi
  run aws iam create-policy-version --policy-arn "${POLICY_ARN}" \
    --policy-document "$(expected_policy_json)" --set-as-default --output json >/dev/null
  ok "Policy updated to the expected document"
}

# -----------------------------------------------------------------------------
# Phase 3 — Cross-account role
# -----------------------------------------------------------------------------

ensure_role() {
  log "Phase 3 — Ensuring role ${ROLE_NAME} trusts LumiTure (${LUMITURE_PRINCIPAL_ARN}) with the ExternalId…"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run aws iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document "$(trust_policy_json)"
    run aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}"
    return 0
  fi

  local out
  if out=$(aws iam create-role --role-name "${ROLE_NAME}" \
             --description "Cross-account role assumed by LumiTure (FinOps billing integration)" \
             --assume-role-policy-document "$(trust_policy_json)" --output json 2>&1); then
    ok "Role created: ${ROLE_ARN}"
  elif grep -q 'EntityAlreadyExists' <<<"${out}"; then
    # Re-run: refresh the trust only when it differs from what we resolved.
    local live_trust
    live_trust=$(aws iam get-role --role-name "${ROLE_NAME}" \
                   --query 'Role.AssumeRolePolicyDocument' --output json)
    if [[ "$(jq -S . <<<"${live_trust}")" == "$(trust_policy_json | jq -S .)" ]]; then
      ok "Role exists with the expected trust policy (idempotent)"
    else
      if [[ "${EXTERNAL_ID_EXPLICIT}" -eq 1 ]]; then
        warn "  Updating the trust policy — if a different ExternalId was already submitted to LumiTure, that submission stops working."
      else
        warn "  Trust policy differs from the expected shape — rewriting it (ExternalId preserved: ${EXTERNAL_ID})."
      fi
      run aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
        --policy-document "$(trust_policy_json)"
      ok "Trust policy updated"
    fi
  else
    die "Role create failed: ${out}"
  fi

  # attach-role-policy is a no-op success when already attached.
  run aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}"
  ok "Policy attached to role"
}

# -----------------------------------------------------------------------------
# Phase 3.5 — Usage monitoring StackSet (opt-in: --with-usage)
#
# Deploys LumiTure's HOSTED member-role template as a SERVICE_MANAGED StackSet:
# every targeted member account gets a read-only monitoring role (CloudWatch +
# EC2 describe) trusting LumiTure with the usage ExternalId. LumiTure validates
# the deployed template byte-for-byte against its hosted copy, so this always
# deploys by --template-url. Side effect to know about: enabling StackSets
# trusted access for the whole Organization (one-time, org-wide).
# Sets global: USAGE_DEPLOYED
# -----------------------------------------------------------------------------

deploy_usage_stackset() {
  USAGE_DEPLOYED=0
  [[ "${WITH_USAGE}" -eq 1 ]] || return 0
  if [[ "${IS_ORG}" -eq 0 ]]; then
    warn "Phase 3.5 — --with-usage needs an AWS Organization; standalone account → skipping the StackSet."
    return 0
  fi

  [[ -n "${USAGE_EXTERNAL_ID}" ]] || USAGE_EXTERNAL_ID=$(gen_external_id)

  log "Phase 3.5 — Checking CloudFormation StackSets trusted access for the Organization…"
  local access
  access=$(aws cloudformation describe-organizations-access --region "${AWS_REGION}" \
             --query Status --output text 2>/dev/null || echo "UNKNOWN")
  if [[ "${access}" != "ENABLED" ]]; then
    log "  Trusted access is ${access} — activating (org-wide, one-time)…"
    run aws cloudformation activate-organizations-access --region "${AWS_REGION}"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [[ "${DRY_RUN}" -eq 1 ]] && break
      access=$(aws cloudformation describe-organizations-access --region "${AWS_REGION}" \
                 --query Status --output text 2>/dev/null || echo "UNKNOWN")
      [[ "${access}" == "ENABLED" ]] && break
      log "  waiting for trusted access to activate (${i}/12)…"
      sleep 10
    done
    [[ "${access}" == "ENABLED" || "${DRY_RUN}" -eq 1 ]] \
      || { fail "StackSets trusted access did not reach ENABLED — the usage StackSet cannot deploy."; return 0; }
  fi
  ok "StackSets trusted access ENABLED"

  log "Phase 3.5 — Creating StackSet ${STACKSET_NAME} from LumiTure's hosted template…"
  local out
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run aws cloudformation create-stack-set --stack-set-name "${STACKSET_NAME}" --template-url "${STACKSET_TEMPLATE_URL}"
  elif out=$(aws cloudformation create-stack-set \
        --stack-set-name "${STACKSET_NAME}" \
        --template-url "${STACKSET_TEMPLATE_URL}" \
        --permission-model SERVICE_MANAGED \
        --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=true \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "${AWS_REGION}" \
        --parameters \
          ParameterKey=RoleName,ParameterValue="${MEMBER_ROLE_NAME}" \
          ParameterKey=ThirdPartyPrincipalArn,ParameterValue="${LUMITURE_PRINCIPAL_ARN}" \
          ParameterKey=ExternalId,ParameterValue="${USAGE_EXTERNAL_ID}" \
        --output json 2>&1); then
    ok "StackSet created"
  elif grep -q 'NameAlreadyExistsException' <<<"${out}"; then
    # The ExternalId parameter is NoEcho — it cannot be read back, so a re-run
    # cannot prove the existing StackSet carries the id we resolved this run.
    warn "  StackSet ${STACKSET_NAME} already exists — reusing it."
    warn "  Its ExternalId cannot be read back (NoEcho): when you submit the usage form,"
    warn "  use the ExternalId from the run that CREATED it, or pass --usage-external-id to match."
  else
    fail "StackSet create failed: ${out}"
    return 0
  fi

  # Targets: explicit OUs, or the org root (= every account, incl. future ones).
  local targets
  if [[ -n "${OU_IDS}" ]]; then
    targets="${OU_IDS//,/ }"
  else
    targets=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
  fi

  local existing_instances
  existing_instances=$(aws cloudformation list-stack-instances --stack-set-name "${STACKSET_NAME}" \
    --region "${AWS_REGION}" --query 'length(Summaries)' --output text 2>/dev/null || echo 0)
  if [[ "${DRY_RUN}" -eq 0 && "${existing_instances}" -gt 0 ]]; then
    ok "StackSet already has ${existing_instances} instance(s) — skipping instance creation"
    USAGE_DEPLOYED=1
    return 0
  fi

  log "Phase 3.5 — Deploying stack instances to: ${targets} (${AWS_REGION})…"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run aws cloudformation create-stack-instances --stack-set-name "${STACKSET_NAME}" --deployment-targets "OrganizationalUnitIds=${targets}"
    return 0
  fi

  # FailureTolerancePercentage defaults to 0, which would stop the whole
  # operation on the first failed account — set it to LumiTure's own 50%
  # threshold so the post-operation tally below is what actually decides.
  local op_id
  op_id=$(aws cloudformation create-stack-instances \
    --stack-set-name "${STACKSET_NAME}" \
    --deployment-targets OrganizationalUnitIds="${targets// /,}" \
    --regions "${AWS_REGION}" \
    --region "${AWS_REGION}" \
    --operation-preferences FailureTolerancePercentage=50 \
    --query OperationId --output text 2>&1) \
    || { fail "create-stack-instances failed: ${op_id}"; return 0; }

  log "  Waiting for the StackSet operation (each member account deploys a stack; can take minutes)…"
  local status="RUNNING" i
  for i in $(seq 1 30); do
    status=$(aws cloudformation describe-stack-set-operation --stack-set-name "${STACKSET_NAME}" \
      --operation-id "${op_id}" --region "${AWS_REGION}" \
      --query 'StackSetOperation.Status' --output text 2>/dev/null || echo "UNKNOWN")
    case "${status}" in
      SUCCEEDED) break ;;
      FAILED|STOPPED) fail "StackSet operation ${op_id} ended ${status} — check the CloudFormation console."; return 0 ;;
    esac
    log "  operation ${status} (${i}/30)…"
    sleep 30
  done
  if [[ "${status}" != "SUCCEEDED" ]]; then
    # A non-terminal operation must never lead to a usage submit — the backend
    # would validate a StackSet that is still deploying.
    fail "StackSet operation still ${status} after 15min — usage will NOT be auto-submitted. Watch it finish in the CloudFormation console, then submit usage in the wizard."
    return 0
  fi

  # LumiTure tolerates up to 50% failed instances; mirror that tally here.
  local total failed
  total=$(aws cloudformation list-stack-instances --stack-set-name "${STACKSET_NAME}" \
    --region "${AWS_REGION}" --query 'length(Summaries)' --output text)
  failed=$(aws cloudformation list-stack-instances --stack-set-name "${STACKSET_NAME}" \
    --region "${AWS_REGION}" --query "length(Summaries[?StackInstanceStatus.DetailedStatus=='FAILED'])" --output text)
  if [[ "${total}" -eq 0 ]]; then
    fail "StackSet has no instances — no member account got the monitoring role."
  elif [[ $((failed * 2)) -gt "${total}" ]]; then
    fail "StackSet instances: ${failed}/${total} FAILED (>50%) — LumiTure will reject the usage integration."
  else
    ok "StackSet instances deployed: $((total - failed))/${total} healthy"
    USAGE_DEPLOYED=1
  fi
}

# -----------------------------------------------------------------------------
# Phase 4 — Output / Submit
# -----------------------------------------------------------------------------

emit_form_values() {
  log "Phase 4 — Form values ready for the LumiTure AWS wizard or API:"
  log "  billing wizard: ${LUMITURE_WIZARD_URL}"
  [[ "${WITH_USAGE}" -eq 1 ]] && log "  usage wizard:   ${LUMITURE_USAGE_WIZARD_URL}"
  if [[ "${WITH_USAGE}" -eq 1 && -n "${USAGE_EXTERNAL_ID}" ]]; then
    cat <<EOF
{
  "billing": {
    "account_id": "${ACCOUNT_ID}",
    "role_arn": "${ROLE_ARN}",
    "policy_arn": "${POLICY_ARN}",
    "external_id": "${EXTERNAL_ID}"
  },
  "usage": {
    "account_id": "${ACCOUNT_ID}",
    "stackset_name": "${STACKSET_NAME}",
    "role_name": "${MEMBER_ROLE_NAME}",
    "external_id": "${USAGE_EXTERNAL_ID}"
  }
}
EOF
  else
    cat <<EOF
{
  "billing": {
    "account_id": "${ACCOUNT_ID}",
    "role_arn": "${ROLE_ARN}",
    "policy_arn": "${POLICY_ARN}",
    "external_id": "${EXTERNAL_ID}"
  }
}
EOF
  fi
}

# POST helper: api_post <path> <payload> <max_time> → sets HTTP_STATUS, HTTP_BODY_FILE
api_post() {
  local path="$1" payload="$2" max_time="${3:-60}"
  HTTP_BODY_FILE=$(mktemp)
  HTTP_STATUS=$(curl -s -o "${HTTP_BODY_FILE}" -w '%{http_code}' --max-time "${max_time}" \
    -X POST "${LUMITURE_API}${path}" \
    -H "Authorization: Bearer ${LUMITURE_JWT}" \
    -H "Content-Type: application/json" \
    -d "${payload}")
}

submit_to_lumiture() {
  [[ -n "${LUMITURE_JWT}" ]] || { ok "Setup done. No --lumiture-jwt → skipping auto-submit; enter the values above in the wizard to finish."; return 0; }
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: would POST permission-check + integration to ${LUMITURE_API}"
    return 0
  fi

  local payload
  payload=$(cat <<EOF
{"account_id": "${ACCOUNT_ID}", "role_arn": "${ROLE_ARN}", "policy_arn": "${POLICY_ARN}", "external_id": "${EXTERNAL_ID}"}
EOF
)

  # Step 1 — permission check. A just-created role/trust regularly fails
  # AssumeRole for 10-60s (IAM eventual consistency), so retry that case.
  log "Phase 4.s — Submitting permission check to ${LUMITURE_API}/platforms/aws/billing/permission-check…"
  local attempt passed=0
  for attempt in 1 2 3 4 5 6; do
    api_post "/platforms/aws/billing/permission-check" "${payload}" 120
    if [[ "${HTTP_STATUS}" -ge 200 && "${HTTP_STATUS}" -lt 300 ]]; then
      ok "Permission check passed (HTTP ${HTTP_STATUS})"
      passed=1
      break
    fi
    if [[ "${HTTP_STATUS}" -eq 403 ]] && grep -q 'PermissionDeny' "${HTTP_BODY_FILE}" && [[ "${attempt}" -lt 6 ]]; then
      warn "  permission check not passing yet (likely IAM propagation) — retrying in 15s (${attempt}/6)…"
      sleep 15
      continue
    fi
    err "Permission check failed: HTTP ${HTTP_STATUS}"
    cat "${HTTP_BODY_FILE}" >&2; echo >&2
    fail "LumiTure permission check rejected the setup — integration not submitted."
    return 0
  done
  [[ "${passed}" -eq 1 ]] || { fail "Permission check still failing after retries."; return 0; }

  # Step 2 — integration. Synchronous and slow: LumiTure assumes the role and
  # creates the two S3 buckets + CUR/FOCUS exports inside this call.
  log "Phase 4.s — Submitting integration (LumiTure now provisions buckets + exports; can take a minute)…"
  api_post "/platforms/aws/billing/integration" "${payload}" 300
  if [[ "${HTTP_STATUS}" -ge 200 && "${HTTP_STATUS}" -lt 300 ]]; then
    ok "Billing integration registered (HTTP ${HTTP_STATUS}) — first cost data lands in ~24h (no backfill)"
  else
    err "Integration failed: HTTP ${HTTP_STATUS}"
    cat "${HTTP_BODY_FILE}" >&2; echo >&2
    fail "LumiTure billing integration failed — see the response above."
    return 0
  fi

  # Step 3 — usage, only after billing succeeded (the backend requires the
  # stored billing credential to validate the StackSet).
  if [[ "${USAGE_DEPLOYED:-0}" -eq 1 ]]; then
    log "Phase 4.s — Submitting usage integration…"
    local usage_payload
    usage_payload=$(cat <<EOF
{"account_id": "${ACCOUNT_ID}", "stackset_name": "${STACKSET_NAME}", "role_name": "${MEMBER_ROLE_NAME}", "external_id": "${USAGE_EXTERNAL_ID}"}
EOF
)
    api_post "/platforms/aws/usage/integration" "${usage_payload}" 120
    if [[ "${HTTP_STATUS}" -ge 200 && "${HTTP_STATUS}" -lt 300 ]]; then
      ok "Usage integration registered (HTTP ${HTTP_STATUS})"
    else
      err "Usage integration failed: HTTP ${HTTP_STATUS}"
      cat "${HTTP_BODY_FILE}" >&2; echo >&2
      fail "LumiTure usage integration failed — billing is connected; fix and submit usage in the wizard."
    fi
  fi
}

# -----------------------------------------------------------------------------
# Phase 5 — Structural self-check (independent read-back)
#
# The shell can't confirm DATA at onboarding time — LumiTure provisions the
# exports after submit and the first run lands ~24h later. But every failure
# that leaves an onboarding silently dead is STRUCTURAL and checkable now:
# a trust policy without the ExternalId, a detached or drifted policy (the #1
# cause of permission-check rejections), a StackSet whose parameters don't
# match what will be submitted. Read the live state back and record anything
# wrong into FAILURES so main() exits non-zero instead of printing a green
# "complete".
# -----------------------------------------------------------------------------

verify_onboarding() {
  [[ "${DRY_RUN}" -eq 1 ]] && { log "Phase 5 — DRY-RUN, skipping verification."; return 0; }
  log "Phase 5 — Verifying the setup is structurally complete (cost data still lands ~1 day after submit)…"

  # Trust policy: LumiTure principal + our ExternalId, no MFA condition.
  local trust
  trust=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null) \
    || { fail "Role ${ROLE_NAME} not readable — was it created?"; trust=""; }
  if [[ -n "${trust}" ]]; then
    local principal eid
    principal=$(jq -r '.Statement[0].Principal.AWS // empty' <<<"${trust}")
    eid=$(jq -r '.Statement[0].Condition.StringEquals."sts:ExternalId" // empty' <<<"${trust}")
    [[ "${principal}" == "${LUMITURE_PRINCIPAL_ARN}" ]] \
      && ok "  ✓ role trusts ${LUMITURE_PRINCIPAL_ARN}" \
      || fail "Role trust principal is '${principal}', expected ${LUMITURE_PRINCIPAL_ARN}."
    [[ "${eid}" == "${EXTERNAL_ID}" ]] \
      && ok "  ✓ trust carries the emitted ExternalId" \
      || fail "Trust ExternalId ('${eid}') differs from the emitted form value ('${EXTERNAL_ID}')."
    grep -q 'MultiFactorAuthPresent' <<<"${trust}" \
      && fail "Trust policy has an MFA condition — LumiTure's programmatic AssumeRole cannot satisfy it; remove it."
  fi

  # Policy attached + document equality — the exact check LumiTure's
  # permission-check runs; a mismatch here IS a rejection there.
  if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
       --query 'AttachedPolicies[].PolicyArn' --output json 2>/dev/null | jq -e --arg p "${POLICY_ARN}" 'index($p)' >/dev/null; then
    ok "  ✓ policy is attached to the role"
  else
    fail "Policy ${POLICY_ARN} is NOT attached to role ${ROLE_NAME}."
  fi
  if policy_doc_matches; then
    ok "  ✓ policy document exactly matches LumiTure's expected document"
  else
    fail "Policy document DIFFERS from LumiTure's expected document (strict-equality check) — permission check will reject it. Re-run this script to rewrite it."
  fi

  # Usage StackSet: parameters + template must match what the backend validates.
  if [[ "${USAGE_DEPLOYED:-0}" -eq 1 ]]; then
    local ss
    ss=$(aws cloudformation describe-stack-set --stack-set-name "${STACKSET_NAME}" \
           --region "${AWS_REGION}" --output json 2>/dev/null) \
      || { fail "StackSet ${STACKSET_NAME} not readable after deploy."; ss=""; }
    if [[ -n "${ss}" ]]; then
      local p_role p_arn
      p_role=$(jq -r '.StackSet.Parameters[] | select(.ParameterKey=="RoleName").ParameterValue' <<<"${ss}")
      p_arn=$(jq -r '.StackSet.Parameters[] | select(.ParameterKey=="ThirdPartyPrincipalArn").ParameterValue' <<<"${ss}")
      [[ "${p_role}" == "${MEMBER_ROLE_NAME}" ]] \
        && ok "  ✓ StackSet RoleName parameter matches the form value" \
        || fail "StackSet RoleName parameter ('${p_role}') differs from the form value ('${MEMBER_ROLE_NAME}')."
      [[ "${p_arn}" == "${LUMITURE_PRINCIPAL_ARN}" ]] \
        && ok "  ✓ StackSet ThirdPartyPrincipalArn is LumiTure's principal" \
        || fail "StackSet ThirdPartyPrincipalArn ('${p_arn}') is not ${LUMITURE_PRINCIPAL_ARN}."
      local live_tb hosted_tb
      live_tb=$(jq -r '.StackSet.TemplateBody' <<<"${ss}")
      hosted_tb=$(curl -s "${STACKSET_TEMPLATE_URL}" || true)
      if [[ -n "${hosted_tb}" && "$(trim "${live_tb}")" == "$(trim "${hosted_tb}")" ]]; then
        ok "  ✓ StackSet template matches LumiTure's hosted copy byte-for-byte"
      elif [[ -z "${hosted_tb}" ]]; then
        warn "  could not fetch the hosted template to compare (network?) — LumiTure re-checks at submit."
      else
        fail "StackSet template body differs from LumiTure's hosted copy — the usage submit will be rejected. Deploy with --template-url only."
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# Main flow
# -----------------------------------------------------------------------------

main() {
  preflight
  check_management_account
  check_export_quota

  if [[ "${DISCOVER_ONLY}" -eq 1 ]]; then
    log "--discover-only mode — account gate + quota confirmed; emitting the values this run WOULD produce, then exiting"
    resolve_external_id
    emit_form_values
    exit 0
  fi

  resolve_external_id
  ensure_policy
  ensure_role
  deploy_usage_stackset

  verify_onboarding

  emit_form_values

  # Don't submit a setup the read-back already proved broken.
  if [[ "${#FAILURES[@]}" -eq 0 ]]; then
    submit_to_lumiture
  else
    err "Skipping auto-submit — the structural check found problems (listed below)."
  fi

  # Never claim success we didn't verify. A failed create only warned above;
  # here it becomes a non-zero exit with a named summary, so a half-broken
  # onboarding (drifted policy, missing attachment, dead StackSet) can't read
  # as complete.
  if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    err "AWS onboarding INCOMPLETE — ${#FAILURES[@]} problem(s):"
    for f in "${FAILURES[@]}"; do err "  • ${f}"; done
    err "Fix the above and re-run. LumiTure cannot connect until every item is resolved."
    exit 1
  fi
  ok "AWS onboarding complete — structure verified. After submitting, LumiTure provisions the exports; first cost data lands in ~24h (integration-time onward, no backfill)."
}

main "$@"
