# LumiTure Azure Onboarding — Cloud Shell

> Guided onboarding for [LumiTure](https://app.lumiture.ai): the customer grants LumiTure read-only access to their Azure cost data — in their own Azure identity, zero install. The Azure analog of the [GCP Cloud Shell flow](../gcp/README.md).

## How the Azure flow differs from GCP

| | GCP | Azure |
|---|---|---|
| Customer grant | IAM on existing BQ export | **Admin-consent** to LumiTure SP **+** RBAC roles |
| One un-scriptable step | Enable billing export (Console-only) | **Admin consent** (Microsoft browser flow) |
| Native shell | Google Cloud Shell (auto-clones repo via badge) | **Azure Cloud Shell** (no auto-clone — `git clone` in Step 0) |
| Data path | BQ dataset read directly | Cost Mgmt **export → Blob → GCS → BigQuery** |
| IaC vehicle | Terraform (`../gcp/terraform/`) | **Bicep** (`bicep/`) |

Because Azure Cloud Shell has no "open this git repo + tutorial" badge like Google's, the entry point is: open Azure Cloud Shell, then clone + start the tutorial.

## Try it

1. Open **Azure Cloud Shell**: <https://shell.azure.com> (pick **Bash**)
2. Clone + enter:
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/azure
   ```
3. Follow [`tutorial.md`](tutorial.md) (or run the wrapper directly — see below)

## What's in this directory

| File | Purpose |
|---|---|
| `tutorial.md` | Step-by-step Cloud Shell walkthrough |
| `onboard-wrapper.sh` | Interactive bash wrapper the customer runs |
| `lumiture-azure-onboard.sh` | Underlying script (consent check + RBAC grants + cost export + form-value output) |
| `bicep/` | Bicep module — declarative alternative (same role grants + export). See `bicep/README.md`. |

**Two ways to run the grant:** the **bash / Cloud Shell** flow (zero-install, customer-driven) or the **Bicep module** in `bicep/` (for teams that prefer IaC). Both grant the same two roles + create the export, and emit the same wizard form values.

## What it does

0. **Pre-flight:** confirms LumiTure's multi-tenant SP is consented in the tenant (browser step done first in the LumiTure wizard). Fails fast with instructions if not.
1. Ensures a storage account + container exist for the Cost Management export
2. Grants `Cost Management Reader` (subscription) and `Storage Blob Data Reader` (storage account) to LumiTure's SP
3. Creates a daily `ActualCost` export (optionally a FOCUS export with `--with-focus`)
4. **(opt-in `--with-usage`)** Creates + assigns the **usage custom role** — `LumiTure FinOps Reader` (VM inventory + `Microsoft.Insights/Metrics/Read`) — for rightsizing/usage data. Billing alone doesn't need it; Cost Management Reader doesn't cover Monitor metrics. Mirrors the backend's `get_usage_custom_role`; validated by the `usage-check` endpoint (which lists VMs).
5. Prints the form values to enter in the LumiTure wizard

Zero install on the customer's machine. Auth stays in the customer's Azure identity. LumiTure never sees the customer's credentials.

> **Billing vs usage are separable.** Billing (cost) is the core flow; usage (rightsizing) is opt-in via `--with-usage` because it grants a broader, compute+metrics read role. Run with `--with-usage` for full FinOps.

## ✅ Validated / ⚠️ Known gap

**Validated end-to-end on sandbox (2026-06-22):** consent → `Cost Management Reader` + `Storage Blob Data Reader` grants → subscription sync = **CONNECTED** + resource groups; `--with-usage` custom role + instance discovery. `LUMITURE_APP_ID_PROD` is set to the prod SP (`c871cf6f-…`); sandbox/dev uses `--lumiture-app-id 99e6a4c9-…`.

**⚠️ KNOWN GAP — billing DATA does not flow yet.** This script does the customer-side **grants + a Cost Management export**, but LumiTure's `transfer_azure_billing_data` reads from **LumiTure's own blob** (`AZURE_LUMITURE_CONTAINER`, authed with the LumiTure SP) at `{tenant}/{subscription}/{YYYYMM}/daily-actual-cost/` — **not** the customer storage this script creates. Getting data there requires wiring the export to LumiTure's **event trigger** (`GET /platforms/azure/authorization/event-trigger-url/` → `AZURE_BILLING_EVENT_TRIGGER_URL`), which this script does **not** do yet. So today the flow reaches `CONNECTED` (subscription/RG sync, usage), but **billing cost data won't land** until the event-trigger step is added (TBD — needs the prod ingestion mechanism documented). Tracked in `backend/tech-debt.md`.

## License

MIT — see [`../LICENSE`](../LICENSE).
