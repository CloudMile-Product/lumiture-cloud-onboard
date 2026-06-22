terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 7.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}

provider "google" {
  project = "your-terraform-runner-project"
}

# Auto-submit variant: after IAM grant succeeds, posts the integration to
# LumiTure's API automatically. Skips the manual "paste form values into the
# wizard" step.
#
# Requires a LumiTure JWT. Obtain an API token for your LumiTure tenant. Pass via TF_VAR_lumiture_jwt environment variable so it
# doesn't land in shell history or tfvars files.
variable "lumiture_jwt" {
  description = "LumiTure user JWT, scoped to the LumiTure tenant being onboarded."
  type        = string
  sensitive   = true
  # Set via: export TF_VAR_lumiture_jwt="$(cat ~/.lumiture/jwt)"
}

module "lumiture_gcp_onboarding" {
  source = "../../"

  billing_account_id     = "012345-6789AB-CDEF01"
  export_project_id      = "my-billing-export-project"
  detailed_usage_dataset = "billing_detailed_export"
  pricing_dataset        = "billing_pricing_export"

  auto_submit_to_lumiture = true
  lumiture_jwt            = var.lumiture_jwt
}

output "next_steps" {
  value = module.lumiture_gcp_onboarding.next_steps
}
