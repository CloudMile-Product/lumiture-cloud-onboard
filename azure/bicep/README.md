# LumiTure Azure Onboarding — Bicep module

Declarative alternative to the bash / Cloud Shell flow. Same end state:
- `Cost Management Reader` → LumiTure SP on the subscription
- `Storage Blob Data Reader` → LumiTure SP on the export storage account
- a daily `ActualCost` Cost Management export → that storage account

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
      storageAccountName=lumitureexport$RANDOM
```

## Files

| File | Scope | Purpose |
|---|---|---|
| `main.bicep` | subscription | RG + storage module + Cost Management Reader + export |
| `storage.bicep` | resource group | storage account + container |
| `role-storage.bicep` | resource group | Storage Blob Data Reader on the storage account |

## Notes

- Built-in role GUIDs are stable across tenants: Cost Management Reader `72fafb9e-0641-4937-9268-a91bfd8191a3`, Storage Blob Data Reader `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`.
- The export `rootFolderPath` (`<tenant>/<subscription>/daily-actual-cost`) must line up with what LumiTure's `transfer_azure_billing_data` task reads — verify against `backend/platforms/azure.md` before promoting out of POC.
- `recurrencePeriod.from` is set to 2026-06-23; adjust if deploying later (must be a future date at deploy time).
