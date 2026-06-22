variable "billing_account_id" {
  description = "Customer's Cloud Billing Account ID, format NNNNNN-NNNNNN-NNNNNN."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must match NNNNNN-NNNNNN-NNNNNN (6 hex chars × 3 groups)."
  }
}

variable "export_project_id" {
  description = "GCP project ID that hosts the Cloud Billing BigQuery export datasets."
  type        = string
}

variable "detailed_usage_dataset" {
  description = "BigQuery dataset ID for the Detailed Usage Cost export."
  type        = string
}

variable "pricing_dataset" {
  description = "BigQuery dataset ID for the Pricing export."
  type        = string
}

variable "lumiture_service_account" {
  description = <<-EOT
    Override the LumiTure service account to grant. Leave null to default to LumiTure production.
  EOT
  type        = string
  default     = null
}

variable "grant_scope" {
  description = <<-EOT
    Scope of the IAM grant:
      - "dataset" (default): grants roles/bigquery.dataViewer on each dataset individually — tight, principle-of-least-privilege.
      - "project": grants on the entire export project — simpler for IAM management, broader access.
  EOT
  type        = string
  default     = "dataset"

  validation {
    condition     = contains(["dataset", "project"], var.grant_scope)
    error_message = "grant_scope must be either \"dataset\" or \"project\"."
  }
}

variable "auto_submit_to_lumiture" {
  description = <<-EOT
    If true, POST the integration to LumiTure's API after the IAM grant succeeds.
    Requires lumiture_jwt. If false (default), use the form_values output to submit via the in-product wizard.
  EOT
  type        = bool
  default     = false
}

variable "lumiture_api_base" {
  description = "LumiTure API base URL. Leave null to default to LumiTure production (https://api.lumiture.ai)."
  type        = string
  default     = null
}

variable "lumiture_jwt" {
  description = "LumiTure JWT for the user submitting the integration. Required if auto_submit_to_lumiture = true."
  type        = string
  default     = null
  sensitive   = true
}
