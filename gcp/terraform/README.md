# terraform-google-lumiture-onboarding

Terraform module that wires up the **GCP-side** of a LumiTure billing data
integration: grants the LumiTure service account `roles/bigquery.dataViewer`
on the customer's BQ billing-export datasets and outputs the form values needed
to complete the integration in LumiTure (via wizard or API).

## What it automates

| Wizard step | Module action |
|---|---|
| 1. Enable billing export to BQ | ❌ Console-only — pre-flight `null_resource` warns if missing data |
| 2–3. Identify datasets | ✅ Customer passes as variables |
| 4. IAM grant | ✅ `google_bigquery_dataset_iam_member` (default) or `google_project_iam_member` (broader) |
| 5. Verify | ✅ `data "google_bigquery_dataset"` reads back after grant |
| 6. Collect form values | ✅ Outputs `lumiture_form_values` (object) + `lumiture_submit_payload_json` (string) |
| 7. (Optional) Submit | ✅ Opt-in `null_resource` with `curl POST` |

## Usage

```hcl
module "lumiture_gcp_onboarding" {
  source  = "lumiture/lumiture-gcp-onboarding/google"
  version = "~> 0.1"

  billing_account_id      = "012345-6789AB-CDEF01"
  export_project_id       = "my-billing-export-project"
  detailed_usage_dataset  = "billing_export"
  pricing_dataset         = "billing_export"

  # Default "dataset" (tight scope). Use "project" for simpler IAM management.
  grant_scope = "dataset"
}

output "lumiture_form_values" {
  value = module.lumiture_gcp_onboarding.lumiture_form_values
}
```

Then submit the integration via the LumiTure wizard at
`https://app.lumiture.ai/authorization/billing-integration/gcp`, or set
`auto_submit_to_lumiture = true` and provide `lumiture_jwt` to POST automatically.

See `examples/basic/` for a complete minimal example.

## Prerequisites

- Cloud Billing export to BigQuery must be **enabled in the GCP Console
  before running this module** — Google Cloud does not expose this as an API
  (verified 2026-05-29 against
  <https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup>).
  The module's freshness check will fail fast if export data is missing.
- The principal running `terraform apply` needs:
  - `roles/bigquery.dataOwner` on the export datasets (for `dataset` grant scope), OR
  - `roles/bigquery.admin` on the export project (for `project` grant scope).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 5.0, < 7.0 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.2 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | 6.50.0 |
| <a name="provider_null"></a> [null](#provider\_null) | 3.3.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_bigquery_dataset_iam_member.lumiture_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/bigquery_dataset_iam_member) | resource |
| [google_project_iam_member.lumiture_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [null_resource.submit_to_lumiture](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [google_bigquery_dataset.detailed_usage](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/bigquery_dataset) | data source |
| [google_bigquery_dataset.pricing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/bigquery_dataset) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_auto_submit_to_lumiture"></a> [auto\_submit\_to\_lumiture](#input\_auto\_submit\_to\_lumiture) | If true, POST the integration to LumiTure's API after the IAM grant succeeds.<br/>Requires lumiture\_jwt. If false (default), use the form\_values output to submit via the in-product wizard. | `bool` | `false` | no |
| <a name="input_billing_account_id"></a> [billing\_account\_id](#input\_billing\_account\_id) | Customer's Cloud Billing Account ID, format NNNNNN-NNNNNN-NNNNNN. | `string` | n/a | yes |
| <a name="input_detailed_usage_dataset"></a> [detailed\_usage\_dataset](#input\_detailed\_usage\_dataset) | BigQuery dataset ID for the Detailed Usage Cost export. | `string` | n/a | yes |
| <a name="input_export_project_id"></a> [export\_project\_id](#input\_export\_project\_id) | GCP project ID that hosts the Cloud Billing BigQuery export datasets. | `string` | n/a | yes |
| <a name="input_grant_scope"></a> [grant\_scope](#input\_grant\_scope) | Scope of the IAM grant:<br/>  - "dataset" (default): grants roles/bigquery.dataViewer on each dataset individually — tight, principle-of-least-privilege.<br/>  - "project": grants on the entire export project — simpler for IAM management, broader access. | `string` | `"dataset"` | no |
| <a name="input_lumiture_api_base"></a> [lumiture\_api\_base](#input\_lumiture\_api\_base) | LumiTure API base URL. Leave null to default to LumiTure production. | `string` | `null` | no |
| <a name="input_lumiture_jwt"></a> [lumiture\_jwt](#input\_lumiture\_jwt) | LumiTure JWT for the user submitting the integration. Required if auto\_submit\_to\_lumiture = true. | `string` | `null` | no |
| <a name="input_lumiture_service_account"></a> [lumiture\_service\_account](#input\_lumiture\_service\_account) | Override the LumiTure service account to grant. Leave null to default to LumiTure production. | `string` | `null` | no |
| <a name="input_pricing_dataset"></a> [pricing\_dataset](#input\_pricing\_dataset) | BigQuery dataset ID for the Pricing export. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_curl_command"></a> [curl\_command](#output\_curl\_command) | Ready-to-paste curl command for the wizard fallback path.<br/>Replace $LUMITURE\_JWT with your LumiTure JWT before running. |
| <a name="output_grant_scope_used"></a> [grant\_scope\_used](#output\_grant\_scope\_used) | Whether IAM was granted at dataset or project scope. |
| <a name="output_granted_service_account"></a> [granted\_service\_account](#output\_granted\_service\_account) | The LumiTure service account that was granted access. |
| <a name="output_lumiture_api_endpoint"></a> [lumiture\_api\_endpoint](#output\_lumiture\_api\_endpoint) | LumiTure API endpoint to POST to (env-derived). |
| <a name="output_lumiture_form_values"></a> [lumiture\_form\_values](#output\_lumiture\_form\_values) | Values to paste into the LumiTure GCP billing-integration wizard. |
| <a name="output_lumiture_submit_payload_json"></a> [lumiture\_submit\_payload\_json](#output\_lumiture\_submit\_payload\_json) | JSON payload ready to POST to LumiTure's API as a fallback to the wizard. |
| <a name="output_next_steps"></a> [next\_steps](#output\_next\_steps) | Human-readable next steps for the operator. |
<!-- END_TF_DOCS -->

