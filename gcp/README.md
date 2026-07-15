# LumiTure GCP Onboarding — Cloud Shell

> 繁體中文（IT SOP）：[`README.zh-TW.md`](README.zh-TW.md)

> Guided **"Open in Cloud Shell"** onboarding for [LumiTure](https://app.lumiture.ai): the customer grants LumiTure read-only access to their GCP billing data — entirely in their own Google identity, zero install. Public so the Cloud Shell URL works without a GitHub auth prompt.

## Try it

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/CloudMile-Product/lumiture-cloud-onboard&cloudshell_tutorial=gcp/tutorial.md&cloudshell_workspace=gcp&show=terminal)

Click the badge → Google Cloud Shell opens in **terminal + tutorial** layout (no IDE editor — `show=terminal`) → guided walkthrough → done.

## What's in this repo

| File | Purpose |
|---|---|
| `tutorial.md` | Step-by-step walkthrough Cloud Shell renders in a side panel |
| `onboard-wrapper.sh` | Interactive bash wrapper the customer runs in the tutorial |
| `init.sh` | Underlying onboarding script (discovery + IAM grant + form-value output) |
| `terraform/` | Terraform module — declarative alternative to the bash flow (same IAM grant + optional auto-submit). See `terraform/README.md` and `terraform/examples/`. |

**Two ways to run the grant:** the **bash / Cloud Shell** flow above (zero-install, customer-driven) or the **Terraform module** in `terraform/` (for teams that prefer IaC / repeatable applies). Both grant the same two roles and emit the same wizard form values.

## What it does

1. Discovers the customer's Cloud Billing Account and BigQuery export dataset
2. Validates the export is producing data
3. Grants `BigQuery Data Viewer` on the export datasets **and** `Billing Account Viewer` (`roles/billing.viewer`) on the billing account to LumiTure's read-only service account — both required by LumiTure's integration validation
4. **(opt-in `--with-usage`)** Grants `roles/monitoring.viewer` on the **scoping project** (default `--export-project`, override with `--scoping-project`) for usage/rightsizing metrics, then optionally registers it via `/platforms/gcp/usage/integration`. This is the Cloud **Monitoring** path — distinct from the "Detailed Usage Cost" *billing* dataset, which is just cost data.
5. Prints the form values to paste into the LumiTure wizard

Zero install on the customer's machine. Auth stays in the customer's Google identity. LumiTure never sees the customer's credentials.

> **Billing vs usage** (same split as the Azure flow): billing (cost) is the core flow; usage (rightsizing, Monitoring metrics) is opt-in via `--with-usage`. ⚠️ Don't confuse GCP's *"Detailed Usage Cost"* (a billing export dataset) with *usage/rightsizing* — the script's `--detailed-usage-dataset` is billing; `--with-usage` is metrics.
>
> **Already billing-onboarded and just need usage?** Use **`--skip-billing`** (usage-only): it skips all billing discovery/grants and does only the `monitoring.viewer` grant + optional usage submit. Implies `--with-usage`; requires `--scoping-project`; needs neither `bq` nor ADC. Example:
> ```bash
> ./init.sh --skip-billing \
>   --scoping-project <project-id> \
>   --lumiture-sa <SA-email>              # prod SA is the default; pass yours if different
> ```

## License

MIT -- see [`LICENSE`](../LICENSE).
