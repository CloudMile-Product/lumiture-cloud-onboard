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
| `preflight.sh` | Read-only permission check to run before the session (see below) |
| `terraform/` | Terraform module — declarative alternative to the bash flow (same IAM grant + optional auto-submit). See `terraform/README.md` and `terraform/examples/`. |

**Two ways to run the grant:** the **bash / Cloud Shell** flow above (zero-install, customer-driven) or the **Terraform module** in `terraform/` (for teams that prefer IaC / repeatable applies). Both grant the same two roles and emit the same wizard form values.

## Before the session — permission check

Run this a few days ahead, **as the person who will run the onboarding**. It is read-only and makes no cloud changes. `READY` means none of the prerequisites it checks is missing, so a missing grant gets fixed before the session instead of during it. Anything it cannot verify counts as `NOT READY`. Add `--with-usage` if usage / rightsizing will be onboarded too.

```bash
curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/gcp/preflight.sh
bash preflight.sh <BILLING_ACCOUNT_ID> [<BILLING_ACCOUNT_ID> ...]
```

It ends with `READY` or `NOT READY`; each `FAIL` line says what is missing or what to do. An export enabled less than a day ago shows `NOT READY` until its first data lands, because `init.sh` stops on an empty export. On a billing account bought through a reseller, it prints the reseller's parent account — the reseller usually holds Billing Account Administrator, so they may need to grant `roles/billing.viewer` instead.

Good to know before running it:
- Not evaluated: organization policies (for example domain-restricted sharing, which can block granting LumiTure's service account from outside your organization), VPC Service Controls, and BigQuery fine-grained dataset ACL enforcement. If your organization uses these, check with your GCP admin.
- Your Cloud Audit Logs will show the read calls it makes under your identity (`testIamPermissions`, `getIamPolicy`, dataset listings, BigQuery dry runs) — expected, nothing is written.
- On an account with many projects, the export scan lists every project's datasets and can take a while; pass `--export-project <id>` to skip it.
- Don't run it with `bash -x`: tracing prints your access token, so that output must never be shared.

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
