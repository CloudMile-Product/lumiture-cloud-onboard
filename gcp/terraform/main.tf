locals {
  # Defaults target LumiTure production (the only environment customers onboard against).
  # To target a different SA / API, set lumiture_service_account / lumiture_api_base.
  default_service_account = "lumiture-client@tw-rd-app-finops-prod.iam.gserviceaccount.com"
  default_api_base        = "https://api.lumiture.ai"

  service_account = coalesce(var.lumiture_service_account, local.default_service_account)
  api_base        = coalesce(var.lumiture_api_base, local.default_api_base)

  iam_member = "serviceAccount:${local.service_account}"

  datasets = toset([var.detailed_usage_dataset, var.pricing_dataset])
}

# -----------------------------------------------------------------------------
# Pre-flight — confirm datasets exist before granting
# -----------------------------------------------------------------------------

data "google_bigquery_dataset" "detailed_usage" {
  project    = var.export_project_id
  dataset_id = var.detailed_usage_dataset
}

data "google_bigquery_dataset" "pricing" {
  project    = var.export_project_id
  dataset_id = var.pricing_dataset
}

# -----------------------------------------------------------------------------
# Phase 2 — IAM grant
# -----------------------------------------------------------------------------

# Dataset-level grant (default — tight scope)
resource "google_bigquery_dataset_iam_member" "lumiture_reader" {
  for_each = var.grant_scope == "dataset" ? local.datasets : toset([])

  project    = var.export_project_id
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = local.iam_member
}

# Project-level grant (alternative — broader)
resource "google_project_iam_member" "lumiture_reader" {
  count = var.grant_scope == "project" ? 1 : 0

  project = var.export_project_id
  role    = "roles/bigquery.dataViewer"
  member  = local.iam_member
}

# Billing-account-level grant — REQUIRED, not optional.
# LumiTure's integration create() validation calls get_account_name() via the
# Cloud Billing API, which needs roles/billing.viewer
# on the billing account. Without it the wizard rejects submit with
# "Permission Denied" even when the BQ dataViewer grant is present.
resource "google_billing_account_iam_member" "lumiture_billing_viewer" {
  billing_account_id = var.billing_account_id
  role               = "roles/billing.viewer"
  member             = local.iam_member
}

# -----------------------------------------------------------------------------
# Phase 3 — Optional auto-submit to LumiTure
# -----------------------------------------------------------------------------

resource "null_resource" "submit_to_lumiture" {
  count = var.auto_submit_to_lumiture ? 1 : 0

  triggers = {
    billing_account_id = var.billing_account_id
    payload_hash       = sha256(local.submit_payload_json)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      [[ -n "${var.lumiture_jwt}" ]] || { echo "lumiture_jwt is required for auto-submit" >&2; exit 1; }
      http_status=$(curl -s -o /tmp/lumiture-submit.out -w '%%{http_code}' \
        -X POST "${local.api_base}/platforms/gcp/billing/integration" \
        -H "Authorization: Bearer ${var.lumiture_jwt}" \
        -H "Content-Type: application/json" \
        -d '${local.submit_payload_json}')
      if [[ "$$http_status" -ge 200 && "$$http_status" -lt 300 ]]; then
        echo "LumiTure submit OK ($$http_status)"
        cat /tmp/lumiture-submit.out
      else
        echo "LumiTure submit failed: HTTP $$http_status" >&2
        cat /tmp/lumiture-submit.out >&2
        exit 1
      fi
    EOT
  }

  depends_on = [
    google_bigquery_dataset_iam_member.lumiture_reader,
    google_project_iam_member.lumiture_reader,
    google_billing_account_iam_member.lumiture_billing_viewer,
  ]
}

locals {
  submit_payload_json = jsonencode({
    billing_account_id = var.billing_account_id
    detailed_usage_cost = {
      project_id = var.export_project_id
      dataset_id = var.detailed_usage_dataset
    }
    pricing = {
      project_id = var.export_project_id
      dataset_id = var.pricing_dataset
    }
  })
}
