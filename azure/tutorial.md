# LumiTure Azure Onboarding — Cloud Shell Walkthrough

<!--
  Azure Cloud Shell renders this as a guided tutorial when opened with
  ?tutorial=azure/tutorial.md (see azure/README.md). Unlike Google Cloud Shell,
  Azure Cloud Shell does not auto-clone a git repo — Step 0 clones it.
-->

Welcome 👋 This walkthrough connects your Azure billing data to LumiTure. Everything runs in Azure Cloud Shell — no install on your computer.

You'll:
1. Confirm LumiTure's service principal is consented in your tenant (one browser step)
2. Identify your subscription + pick a storage account for the cost export
3. Grant LumiTure read-only access (Cost Management Reader + Storage Blob Data Reader)
4. Create the daily cost export and get the values to enter in LumiTure's wizard

## Step 0 — Get this repo into Cloud Shell

Azure Cloud Shell already has `az`, `jq`, and `git`, and you're logged in automatically. Clone this repo:

```bash
git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/azure
```

Confirm you're on the right account:

```bash
az account show --query "{user:user.name, tenant:tenantId, subscription:name, id:id}" -o table
```

If the wrong subscription is active, list them and pick one in Step 2.

## Step 1 — Grant admin consent (browser, one-time per tenant)

LumiTure reads your data through a **multi-tenant service principal** that must be consented into your Azure tenant once. This is a Microsoft browser flow — it can't be scripted.

1. Open the LumiTure app → **Authorization → Connect Azure**, or go directly to
   <https://app.lumiture.ai/authorization/billing-data-integration/azure>
2. Enter the subscription you want to onboard. You'll be redirected to Microsoft.
3. Sign in as a **tenant admin** and click **Accept** on the consent prompt.

> **Already consented this tenant before?** Skip to Step 2 — subsequent subscriptions don't need a new consent.

Verify the service principal landed in your tenant (replace the app id with the one shown in the LumiTure wizard):

```bash
read -p "LumiTure App (client) ID from the wizard: " LUMITURE_APP_ID
az ad sp show --id "${LUMITURE_APP_ID}" --query "{name:displayName, objectId:id}" -o table
```

If you see a name + objectId, consent succeeded. Click **Next**.

## Step 2 — Pick your subscription

```bash
az account list --query "[].{name:name, id:id, state:state}" -o table
read -p "Subscription ID to onboard: " SUBSCRIPTION_ID
az account set --subscription "${SUBSCRIPTION_ID}"
echo "Active subscription: ${SUBSCRIPTION_ID}"
```

## Step 3 — Choose a storage account for the cost export

Azure delivers Cost Management exports to a blob storage account. Pick a name (lowercase, 3–24 chars, globally unique) and a resource group — the script creates them if they don't exist.

```bash
read -p "Storage account name (e.g. lumitureexport$RANDOM): " STORAGE_ACCOUNT
read -p "Resource group for it (e.g. lumiture-billing-rg): " STORAGE_RG
```

## Step 4 — Run the grant + export

Review what the script will do first:

```bash
cat onboard-wrapper.sh
```

Then run it:

```bash
bash onboard-wrapper.sh "${SUBSCRIPTION_ID}" "${STORAGE_ACCOUNT}" "${STORAGE_RG}" "${LUMITURE_APP_ID}"
```

What the script does:
1. Confirms LumiTure's SP is consented (Step 1)
2. Ensures the storage account + `billing-exports` container exist
3. Grants `Cost Management Reader` on the subscription and `Storage Blob Data Reader` on the storage account to LumiTure's SP
4. Creates a daily **ActualCost** export rooted at `<tenant>/<subscription>/daily-actual-cost/`
5. Prints the JSON form values

You'll see ✅ checkmarks as each step succeeds.

## Step 5 — Finish in LumiTure

The script prints:

```json
{
  "tenant_id": "...",
  "subscription_id": "...",
  "storage_account": "...",
  "container": "billing-exports"
}
```

Open the LumiTure Azure wizard:

> <https://app.lumiture.ai/authorization/billing-data-integration/azure>

Enter the values and submit. The subscription status moves to `IN_PROGRESS`, then `CONNECTED` once LumiTure's subscription sync runs.

## Step 6 — When does data appear?

- **Connection** (CONNECTED): once the subscription sync runs after submit.
- **Cost data**: Azure's first daily export run lands within ~24h, then LumiTure transfers blob → BigQuery on its schedule. Rows also restate over ~30 days as Azure finalizes cost.

So the connection is near-immediate; populated dashboards follow within a day.

## Cleanup / revoke

Nothing was installed on your computer. To revoke later:

```bash
# remove the role grants
az role assignment delete --assignee "${LUMITURE_APP_ID}" --scope "/subscriptions/${SUBSCRIPTION_ID}"
# delete the export
az costmanagement export delete --name lumiture-daily-actual-cost --scope "subscriptions/${SUBSCRIPTION_ID}"
```

---

**Issues?** File at <https://github.com/CloudMile-Product/lumiture-cloud-onboard/issues> or contact your LumiTure rep.
