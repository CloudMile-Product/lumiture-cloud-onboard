# LumiTure Azure Onboarding — Cloud Shell

> 繁體中文（IT SOP）：[`README.zh-TW.md`](README.zh-TW.md)

> Guided onboarding for [LumiTure](https://app.lumiture.ai): the customer grants LumiTure read-only access to their Azure cost data — in their own Azure identity, zero install. The Azure analog of the [GCP Cloud Shell flow](../gcp/README.md).

## How the Azure flow differs from GCP

| | GCP | Azure |
|---|---|---|
| Customer grant | IAM on existing BQ export | **Admin-consent** to LumiTure SP **+** RBAC roles |
| One un-scriptable step | Enable billing export (Console-only) | **Admin consent** (Microsoft browser flow) |
| Native shell | Google Cloud Shell (auto-clones repo via badge) | **Azure Cloud Shell** (no auto-clone — `git clone` in Step 0) |
| Data path | BQ dataset read directly | Cost Mgmt **export → Blob → GCS → BigQuery** |
| IaC vehicle | Terraform (`../gcp/terraform/`) | **Bicep** (`bicep/`) |

Because Azure Cloud Shell has no "open this git repo + tutorial" badge like Google's, the entry point is: open Azure Cloud Shell, then clone + run `init.sh`.

## Try it

> ⚠️ **First time on this tenant? Do the one-time admin consent _before_ running anything.** LumiTure reads your data through a multi-tenant service principal that must be **consented into your tenant once** — a Microsoft **browser** step that cannot be scripted. In the LumiTure app: **Authorization → Connect Azure** → sign in as a **tenant admin** → **Accept**. Until the SP is consented, the script stops at **Phase 0** and applies no grants. Already consented this tenant? Skip it — later subscriptions do not need a new consent. Full steps: [`tutorial.md` → Step 1](tutorial.md).

1. Open **Azure Cloud Shell**: <https://shell.azure.com> (pick **Bash**)
2. Clone + enter:
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/azure
   ```
3. Run the script, passing the **event-trigger URL LumiTure gives you**:
   ```bash
   ./init.sh --event-trigger-url <event-trigger URL provided by LumiTure>
   ```

> ⚠️ **`--event-trigger-url` is required for data to flow.** Without it the script applies the grants and creates the exports but skips the Event Grid subscription, so **billing data never reaches LumiTure**. The Phase 4 check catches this and **exits non-zero** naming the missing subscription — but the grants and exports it already made are real, so re-run with the URL rather than assuming nothing happened. The URL is env-specific (prod/dev/staging differ) and is not published here — get it from your LumiTure contact or the Azure wizard.

Every other argument defaults correctly for production: **subscription** = your active `az` subscription, **tenant** = that login's tenant, **storage account** = auto-derived (`ltexp…`), **resource group** = `lumiture-billing-rg`, **LumiTure SP / API** = prod, **usage role + FOCUS export** = on.

> **Multiple subscriptions?** `init.sh` silently uses whichever is *active*. Name the one you mean:
> ```bash
> ./init.sh --subscription-id <GUID> --event-trigger-url <URL>
> ```

4. Enter the printed form values into the [LumiTure wizard](https://app.lumiture.ai/authorization/billing-integration/azure) to finish.

## What's in this directory

| File | Purpose |
|---|---|
| `init.sh` | **The onboarding script — run this.** Consent pre-flight + RBAC grants + cost export + Event Grid subscription + structural self-check + form-value output |
| `tutorial.md` | Step-by-step Cloud Shell walkthrough (**optional** — `init.sh` is self-contained; read this only if you want each phase explained) |
| `bicep/` | Bicep module — declarative alternative (same role grants + export + Event Grid). See `bicep/README.md`. |

**Two ways to run the grant:** the **bash / Cloud Shell** flow above (zero-install, customer-driven) or the **Bicep module** in `bicep/` (for teams that prefer IaC / review-then-apply). Both grant the same roles, create the same exports, and emit the same wizard form values — and **both need the event-trigger URL** (`--event-trigger-url` / `eventTriggerUrl`) or billing data will not flow. Bicep additionally emits an `eventSubscriptionWired` output so you can confirm the data path was actually created.

## What it does

0. **Pre-flight:** confirms LumiTure's multi-tenant SP is consented in the tenant (browser step done first in the LumiTure wizard). Fails fast with instructions if not.
1. Ensures a storage account + container exist for the Cost Management export, and sets a lifecycle rule that auto-deletes export blobs older than **180 days** (`--export-retention-days <n>` to tune, `--no-retention` to skip) — the daily exports never de-duplicate, so this keeps storage cost flat
2. Grants `Cost Management Reader` (subscription) and `Storage Blob Data Reader` (storage account) to LumiTure's SP
3. Creates a daily `ActualCost` export **and** (default) a FOCUS-format export — `--no-focus` to skip. If the export comes back carrying its own managed identity, grants that identity write access on the storage account — see [Export managed identity](#export-managed-identity)
4. **(default)** Creates + assigns the **usage custom role** — `LumiTure FinOps Reader` (VM inventory + `Microsoft.Insights/Metrics/Read`) — for rightsizing/usage data. Cost Management Reader doesn't cover Monitor metrics. LumiTure validates this grant by listing VMs. Pass `--no-usage` for a minimal billing-only grant.
5. Creates the **Event Grid subscription** (`BlobCreated` → LumiTure webhook) — the data path — when `--event-trigger-url` is supplied; skipped with a warning if it isn't, and the Phase 4 check below then **fails the run**
6. **(default)** Seeds **3 months of history** as one-time exports, one per month, so your first dashboard shows a trend instead of only the current month — `--backfill-months <n>` to tune, `--backfill-months 0` to skip. Runs only once the Event Grid subscription (step 5) is actually wired — one-time exports never re-deliver, so without a listener the history would be lost; if step 5 was skipped, the backfill is skipped too (with a warning) and a later re-run with `--event-trigger-url` seeds it
7. **Verifies the result (Phase 4)** by reading the live state back: both exports exist and target the storage account this run derived, every export managed identity has write access, and the Event Grid subscription points at the trigger URL you passed. See [Failures are fatal](#failures-are-fatal)
8. Prints the form values to enter in the LumiTure wizard

Zero install on the customer's machine. Auth stays in the customer's Azure identity. LumiTure never sees the customer's credentials.

> **History is captured at onboarding, or not at all.** LumiTure's service principal is granted **read-only** access, which means it cannot create Cost Management exports — and an export is the only way to obtain historical FOCUS data. This script runs as *you* (subscription Owner), so it is the one place the backfill can happen. If you onboard with `--backfill-months 0`, recovering that history later requires re-running the script.

> **Full FinOps by default.** The script grants the broader compute+metrics read role and creates the FOCUS export out of the box, so cost *and* rightsizing work immediately. For a **least-privilege, billing-only** onboarding, run with `--no-usage` (and `--no-focus`): you'll get just `Cost Management Reader` + `Storage Blob Data Reader` + the ActualCost export.

## Billing data path

Cost data flows to LumiTure via an **event trigger**, not by LumiTure reading your storage directly: your storage fires `BlobCreated` → Event Grid webhook → LumiTure ingests the export into its own managed storage.

**Phase 2.7 creates that Event Grid subscription, and it only runs when you pass `--event-trigger-url`** (see [Try it](#try-it)). Omit it and Phase 2.7 warns and returns — the grants and exports still succeed, but no blobs ever reach LumiTure. Phase 4 then fails the run so this cannot pass as a successful onboarding.

The endpoint must be a real function (it answers Event Grid's validation handshake) — a placeholder URL fails. Cost data lands once the export's first daily run completes (~24h).

## Export managed identity

A Cost Management export does not write to your storage as LumiTure's service principal — it writes as **its own identity**.

When the storage account **disallows shared-key access** (common under CSP and enterprise security policy), Azure gives the export a managed identity and writes through that instead. The identity needs `Storage Blob Data Contributor` on the storage account, or every export run fails with `AccessToStorageAccountDenied` — and Azure surfaces none of it: the export exists, reads as healthy in the Portal, and simply produces no blobs.

`init.sh` checks for that identity after creating each export and grants the role when one is present (safe to re-run). Only the script can do this, because it runs as **you**, a subscription Owner — LumiTure's read-only SP cannot grant roles, so this cannot be fixed from LumiTure's side afterwards. On shared-key-allowed storage the export has no such identity and the step is skipped.

## Failures are fatal

Anything that would leave the pipeline half-wired — a failed export or role create, a missing Event Grid subscription, an export pointed at a different storage account, an export identity without write access — is collected, and the script **exits non-zero listing each problem**. A green `Azure onboarding complete` means the structure was read back and checked, not merely that the script reached the end.

Phase 4 deliberately verifies **structure, not data**: the exports are dated from tomorrow and nothing has run yet. Cost data lands ~1 day later, so confirm the dashboard tomorrow rather than immediately.

> **A second export with the same name pointing at a different storage account** is usually left over from an earlier run, and splits your data across two places. Phase 4 warns about it. Delete it in the Portal: deleting by name from the CLI hits the wrong one.

## License

MIT — see [`../LICENSE`](../LICENSE).
