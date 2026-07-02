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

> ⚠️ **First time on this tenant? Do the one-time admin consent _before_ running anything.** LumiTure reads your data through a multi-tenant service principal that must be **consented into your tenant once** — a Microsoft **browser** step that cannot be scripted. In the LumiTure app: **Authorization → Connect Azure** → sign in as a **tenant admin** → **Accept**. Until the SP is consented, the script stops at **Phase 0** and applies no grants. Already consented this tenant? Skip it — later subscriptions do not need a new consent. Full steps: [`tutorial.md` → Step 1](tutorial.md).

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
| `init.sh` | Underlying script (consent check + RBAC grants + cost export + form-value output) |
| `bicep/` | Bicep module — declarative alternative (same role grants + export). See `bicep/README.md`. |

**Two ways to run the grant:** the **bash / Cloud Shell** flow (zero-install, customer-driven) or the **Bicep module** in `bicep/` (for teams that prefer IaC). Both grant the same two roles + create the export, and emit the same wizard form values.

## What it does

0. **Pre-flight:** confirms LumiTure's multi-tenant SP is consented in the tenant (browser step done first in the LumiTure wizard). Fails fast with instructions if not.
1. Ensures a storage account + container exist for the Cost Management export, and sets a lifecycle rule that auto-deletes export blobs older than **180 days** (`--export-retention-days <n>` to tune, `--no-retention` to skip) — the daily exports never de-duplicate, so this keeps storage cost flat
2. Grants `Cost Management Reader` (subscription) and `Storage Blob Data Reader` (storage account) to LumiTure's SP
3. Creates a daily `ActualCost` export **and** (default) a FOCUS-format export — `--no-focus` to skip
4. **(default)** Creates + assigns the **usage custom role** — `LumiTure FinOps Reader` (VM inventory + `Microsoft.Insights/Metrics/Read`) — for rightsizing/usage data. Cost Management Reader doesn't cover Monitor metrics. LumiTure validates this grant by listing VMs. Pass `--no-usage` for a minimal billing-only grant.
5. Prints the form values to enter in the LumiTure wizard (or auto-registers when run with a session token)

Zero install on the customer's machine. Auth stays in the customer's Azure identity. LumiTure never sees the customer's credentials.

> **Full FinOps by default.** The script grants the broader compute+metrics read role and creates the FOCUS export out of the box, so cost *and* rightsizing work immediately. For a **least-privilege, billing-only** onboarding, run with `--no-usage` (and `--no-focus`): you'll get just `Cost Management Reader` + `Storage Blob Data Reader` + the ActualCost export.

## Billing data path

Cost data flows to LumiTure via an **event trigger**, not by LumiTure reading your storage directly: your storage fires `BlobCreated` → Event Grid webhook → LumiTure ingests the export into its own managed storage. **Phase 2.7 of this script creates that Event Grid subscription** (pass `--event-trigger-url`, or `--lumiture-api` + `--lumiture-jwt` to fetch it). The endpoint must be a real function (it answers Event Grid's validation handshake) — a placeholder URL fails. Cost data lands once the export's first daily run completes (~24h).

## License

MIT — see [`../LICENSE`](../LICENSE).
