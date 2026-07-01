# LumiTure Azure Onboarding — Bicep module

Declarative alternative to the bash / Cloud Shell flow. Same end state:
- `Cost Management Reader` → LumiTure SP on the subscription
- `Storage Blob Data Reader` → LumiTure SP on the export storage account
- a daily `ActualCost` Cost Management export → that storage account
- an Event Grid subscription (BlobCreated → LumiTure webhook) so the export blobs actually reach LumiTure — the **data path** (wired only when `eventTriggerUrl` is supplied)

## Prerequisite (un-scriptable)

LumiTure's multi-tenant service principal must already be **consented** in your tenant — do that once via the LumiTure **Connect Azure** wizard (Microsoft browser flow). Then get its object id:

```bash
az ad sp show --id <LUMITURE_APP_ID> --query id -o tsv
```

## Deploy

```bash
az deployment sub create \
  --location eastasia \
  --template-file main.bicep \
  --parameters \
      lumitureSpObjectId=<sp-object-id> \
      storageResourceGroup=lumiture-billing-rg \
      storageAccountName=lumitureexport$RANDOM \
      eventTriggerUrl=<LumiTure billing event-trigger URL>
```

`eventTriggerUrl` is env-specific (get it from the LumiTure Azure wizard/API). Omit it and the deploy still creates the grants + export, but **billing data won't flow** until the Event Grid subscription exists — `az bicep`'s `eventSubscriptionWired` output tells you which happened.

## Files

| File | Scope | Purpose |
|---|---|---|
| `main.bicep` | subscription | RG + storage module + Cost Management Reader + export + Event Grid |
| `storage.bicep` | resource group | storage account + container |
| `role-storage.bicep` | resource group | Storage Blob Data Reader on the storage account |
| `eventgrid.bicep` | resource group | Event Grid system topic + BlobCreated → LumiTure webhook (data path) |

## Notes

- Built-in role GUIDs are stable across tenants: Cost Management Reader `72fafb9e-0641-4937-9268-a91bfd8191a3`, Storage Blob Data Reader `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`.
- The export `rootFolderPath` (`cost`) + export name (`daily-actual-cost`) must line up with what LumiTure's billing-event ingestion reads: container `billing-export`, prefix `cost/daily-actual-cost/`. Keep these values in sync with the shell defaults before promoting out of POC.
- `recurrencePeriod.from` defaults to `dateTimeAdd(utcNow(), 'P1D')` (one day out), because Azure requires the schedule start to be in the future at deploy time. It's computed per deploy — don't override it with a literal, which would eventually fail validation.
