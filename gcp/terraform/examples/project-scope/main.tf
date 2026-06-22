terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "google" {
  project = "your-terraform-runner-project"
}

# Project-scope variant: grants roles/bigquery.dataViewer at the export project
# instead of on each dataset. Simpler IAM management, broader scope.
#
# Trade-off: LumiTure can read ALL BQ datasets in the export project, not just
# the billing/pricing ones. Prefer "dataset" scope (the default) unless your
# security policy requires project-level IAM management.
module "lumiture_gcp_onboarding" {
  source = "../../"

  billing_account_id     = "012345-6789AB-CDEF01"
  export_project_id      = "my-billing-export-project"
  detailed_usage_dataset = "billing_detailed_export"
  pricing_dataset        = "billing_pricing_export"

  grant_scope = "project"
}

output "lumiture_form_values" {
  description = "Paste these into https://app.lumiture.ai/authorization/billing-integration/gcp"
  value       = module.lumiture_gcp_onboarding.lumiture_form_values
}

output "grant_scope_used" {
  value = module.lumiture_gcp_onboarding.grant_scope_used
}

output "next_steps" {
  value = module.lumiture_gcp_onboarding.next_steps
}
