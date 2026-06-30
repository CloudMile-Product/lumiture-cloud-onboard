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
4. **(opt-in `--with-usage`)** Creates + assigns the **usage custom role** — `LumiTure FinOps Reader` (VM inventory + `Microsoft.Insights/Metrics/Read`) — for rightsizing/usage data. Billing alone doesn't need it; Cost Management Reader doesn't cover Monitor metrics. LumiTure validates this grant by listing VMs.
5. Prints the form values to enter in the LumiTure wizard

Zero install on the customer's machine. Auth stays in the customer's Azure identity. LumiTure never sees the customer's credentials.

> **Billing vs usage are separable.** Billing (cost) is the core flow; usage (rightsizing) is opt-in via `--with-usage` because it grants a broader, compute+metrics read role. Run with `--with-usage` for full FinOps.

## Billing data path

Cost data flows to LumiTure via an **event trigger**, not by LumiTure reading your storage directly: your storage fires `BlobCreated` → Event Grid webhook → LumiTure ingests the export into its own managed storage. **Phase 2.7 of this script creates that Event Grid subscription** (pass `--event-trigger-url`, or `--lumiture-api` + `--lumiture-jwt` to fetch it). The endpoint must be a real function (it answers Event Grid's validation handshake) — a placeholder URL fails. Cost data lands once the export's first daily run completes (~24h).

## License

MIT — see [`../LICENSE`](../LICENSE).
