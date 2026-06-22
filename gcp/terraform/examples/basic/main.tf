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
  # Used for the Terraform provider session only — NOT for IAM bindings.
  # IAM bindings target var.export_project_id below.
  project = var.terraform_runner_project
}

variable "terraform_runner_project" {
  description = "GCP project to use for the Terraform google provider session (any project where the runner is authenticated)."
  type        = string
}

variable "billing_account_id" {
  description = "Customer's Cloud Billing Account ID."
  type        = string
}

variable "export_project_id" {
  description = "GCP project hosting the billing-export BQ datasets."
  type        = string
}

variable "detailed_usage_dataset" {
  description = "BQ dataset for Detailed Usage Cost export."
  type        = string
}

variable "pricing_dataset" {
  description = "BQ dataset for Pricing export."
  type        = string
}

# Minimal example: wire the LumiTure prod SA to read the customer's billing export.
# Assumes Cloud Billing export to BigQuery is ALREADY enabled in the Console.
module "lumiture_gcp_onboarding" {
  source = "../../"

  billing_account_id     = var.billing_account_id
  export_project_id      = var.export_project_id
  detailed_usage_dataset = var.detailed_usage_dataset
  pricing_dataset        = var.pricing_dataset

  # Default grant_scope = "dataset" (tight). Switch to "project" if you prefer simpler IAM.
}

output "lumiture_form_values" {
  description = "Paste these into https://app.lumiture.ai/authorization/billing-integration/gcp"
  value       = module.lumiture_gcp_onboarding.lumiture_form_values
}

output "next_steps" {
  value = module.lumiture_gcp_onboarding.next_steps
}

output "curl_command" {
  description = "Curl-fallback for the wizard path. Replace \\$LUMITURE_JWT before running."
  value       = module.lumiture_gcp_onboarding.curl_command
}
