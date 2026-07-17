# LumiTure GCP Onboarding — Cloud Shell Walkthrough

<walkthrough-author name="LumiTure Team" repositoryUrl="https://github.com/CloudMile-Product/lumiture-cloud-onboard"></walkthrough-author>

Welcome 👋 This 5-minute walkthrough connects your GCP Cloud Billing data to LumiTure. Everything runs in this browser — no install on your computer.

You'll:
1. Verify your billing export is enabled
2. Identify your Billing Account + export dataset
3. Grant LumiTure read-only access on your billing data
4. Get the values to paste into LumiTure's wizard

Click **Start** to begin.

## Pre-flight check

Cloud Shell already has `gcloud`, `bq`, and `jq` installed — no setup needed. Let's confirm you're logged in:

```bash
gcloud auth list
```

You should see your Google account marked as `ACTIVE`. If not, run `gcloud auth login` and follow the prompts.

Also confirm Application Default Credentials are set (needed for the `bq` commands):

```bash
gcloud auth application-default print-access-token > /dev/null && echo "✅ ADC ready" || gcloud auth application-default login
```

When you see `✅ ADC ready`, you're good. Click **Next**.

## Step 1 — Confirm billing export is enabled

LumiTure reads from your **Cloud Billing data export to BigQuery**. If you've already enabled this (most companies have, for their finance team), skip to Step 2. If not, you need to enable it in the Cloud Console first:

<walkthrough-pin-section-icon></walkthrough-pin-section-icon>

1. Open <https://console.cloud.google.com/billing> in a new tab
2. Pick your billing account → **Billing export** → **BigQuery export**
3. Enable **Detailed usage cost** and **Pricing** (both — separate buttons)
4. Wait ~24h for the first batch of data to land

> **Already had export enabled?** No wait — continue.

Click **Next** once your export is configured AND data is flowing.

## Step 2 — Find your Billing Account ID

```bash
gcloud billing accounts list
```

Copy the **ACCOUNT_ID** for the billing account you want to onboard. It looks like `NNNNNN-NNNNNN-NNNNNN` (hex characters, three groups of six).

Save it for the next step:

```bash
read -p "Paste your Billing Account ID: " BILLING_ACCOUNT_ID
echo "Set BILLING_ACCOUNT_ID=${BILLING_ACCOUNT_ID}"
```

## Step 3 — Find your export project and dataset

The billing export lives in a project + dataset that you chose when you enabled it. If you set it up, you know where it is. If not, your finance/ops team does.

List projects under this billing account:

```bash
gcloud billing projects list --billing-account=${BILLING_ACCOUNT_ID}
```

Pick the project where the export lives, then:

```bash
read -p "Export project ID: " EXPORT_PROJECT_ID
bq ls --project_id=${EXPORT_PROJECT_ID}
```

You'll see your datasets. Look for the billing-export one (often named `billing_export`, `gcp_billing`, or similar).

```bash
read -p "Detailed Usage Cost dataset: " DETAILED_USAGE_DATASET
read -p "Pricing dataset (may be the same as above): " PRICING_DATASET
```

## Step 4 — Quick freshness check

Let's verify the export is actually flowing data:

```bash
bq query --use_legacy_sql=false --project_id=${EXPORT_PROJECT_ID} --format=pretty \
  "SELECT COUNT(*) AS rows, MAX(export_time) AS latest
   FROM \`${EXPORT_PROJECT_ID}.${DETAILED_USAGE_DATASET}.gcp_billing_export_resource_v1_*\`"
```

Expect `rows > 0` and `latest` within the last ~24h.

If you see 0 rows: export was probably enabled less than 24h ago. Come back tomorrow — your computer doesn't need to be on, GCP delivers the data automatically.

If you see "Not found: Table": you enabled **Standard usage cost** only, not **Detailed usage cost**. Go back to the Console and enable Detailed.

## Step 5 — Grant LumiTure read access

LumiTure's service account needs two read-only roles: `BigQuery Data Viewer` on your billing export datasets **and** `Billing Account Viewer` on your billing account (both are required so LumiTure can validate and read your billing data). The script below does this for you — review what it'll do first:

```bash
cat onboard-wrapper.sh
```

It's ~50 lines of bash that calls our underlying onboarding script. Read it if you want to be sure what it does.

Then run it:

```bash
bash onboard-wrapper.sh \
  "${BILLING_ACCOUNT_ID}" \
  "${EXPORT_PROJECT_ID}" \
  "${DETAILED_USAGE_DATASET}" \
  "${PRICING_DATASET}"
```

What the script does:
1. Validates the freshness check passed (Step 4)
2. Grants `roles/bigquery.dataViewer` on your datasets **and** `roles/billing.viewer` on your billing account to `lumiture-client@tw-rd-app-finops-prod.iam.gserviceaccount.com`
3. Prints the JSON form values to paste into LumiTure

You'll see ✅ checkmarks as each step succeeds.

## Step 6 — Paste form values into LumiTure

The script prints a JSON blob like this:

```json
{
  "billing_account_id": "012345-...",
  "detailed_usage_cost": { "project_id": "...", "dataset_id": "..." },
  "pricing": { "project_id": "...", "dataset_id": "..." }
}
```

Open the LumiTure wizard in a new tab:

> <https://app.lumiture.ai/authorization/billing-integration/gcp>

Copy the 5 values from the JSON into the wizard's form fields. Click **Submit**.

The status should flip from `IN_PROGRESS` to `CONNECTED` within ~15 seconds.

## Step 7 — Watch the data appear

Within ~5–15 minutes, your dashboard at <https://app.lumiture.ai/dashboard> will start rendering cost data.

That's it. Every new GCP project your team adds under this Billing Account will appear in LumiTure automatically — no need to re-onboard.

## What if I have more than one Billing Account?

Re-run this tutorial for each BA. The integration is per-BA, not per-project.

## Cleanup

This walkthrough didn't install anything on your computer. The Cloud Shell session will terminate automatically after 20 minutes of inactivity. The IAM grant you made on your BigQuery dataset persists — you can revoke it any time in the Cloud Console.

---

**Issues?** Contact your LumiTure rep.
