output "lumiture_form_values" {
  description = "Values to paste into the LumiTure GCP billing-integration wizard."
  value = {
    billing_account_id = var.billing_account_id
    detailed_usage_cost = {
      project_id = var.export_project_id
      dataset_id = var.detailed_usage_dataset
    }
    pricing = {
      project_id = var.export_project_id
      dataset_id = var.pricing_dataset
    }
  }
}

output "lumiture_submit_payload_json" {
  description = "JSON payload ready to POST to LumiTure's API as a fallback to the wizard."
  value       = local.submit_payload_json
}

output "lumiture_api_endpoint" {
  description = "LumiTure API endpoint to POST to (env-derived)."
  value       = "${local.api_base}/platforms/gcp/billing/integration"
}

output "curl_command" {
  description = <<-EOT
    Ready-to-paste curl command for the wizard fallback path.
    Replace $LUMITURE_JWT with your LumiTure JWT before running.
  EOT
  value = format(
    "curl -X POST %s/platforms/gcp/billing/integration -H 'Authorization: Bearer $LUMITURE_JWT' -H 'Content-Type: application/json' -d '%s'",
    local.api_base,
    local.submit_payload_json
  )
}

output "granted_service_account" {
  description = "The LumiTure service account that was granted access."
  value       = local.service_account
}

output "grant_scope_used" {
  description = "Whether IAM was granted at dataset or project scope."
  value       = var.grant_scope
}

output "next_steps" {
  description = "Human-readable next steps for the operator."
  value = var.auto_submit_to_lumiture ? (
    "Integration submitted to ${local.api_base}. Refresh https://app.lumiture.ai/authorization to confirm CONNECTED."
    ) : (
    join("", [
      "IAM grant applied. To complete integration:\n",
      "  Option 1 (wizard): open https://app.lumiture.ai/authorization/billing-integration/gcp ",
      "and paste the form values from `terraform output lumiture_form_values`.\n",
      "  Option 2 (curl):   curl -X POST ${local.api_base}/platforms/gcp/billing/integration ",
      "-H 'Authorization: Bearer <YOUR_JWT>' -H 'Content-Type: application/json' ",
      "-d \"$(terraform output -raw lumiture_submit_payload_json)\""
    ])
  )
}
