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

## Step 0 — Open Cloud Shell and get this repo

Open Azure Cloud Shell from the portal (the `>_` icon, top bar) or <https://portal.azure.com/#cloudshell/>.

**First launch?** In the *Getting started* pane, choose **"No storage account required"** (ephemeral session), leave **"Use existing private virtual network"** *unchecked*, pick **Bash**, and click **Apply**. This onboarding is a one-shot run and keeps nothing in the shell's home directory, so you don't need to create a storage account or configure a virtual network just to use Cloud Shell. (Ticking the private-VNet box is what triggers the extra "virtual network settings" dialog — skip it.)

> ⚠️ Don't confuse this with the export storage account. The Cloud Shell prompt above is only for the shell's own scratch space — skip it. The storage account that *receives your cost export* is a separate one the script creates for you in Step 3.

Cloud Shell already has `az`, `jq`, and `git`, and you're logged in automatically. Clone this repo:

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
   <https://app.lumiture.ai/authorization/billing-integration/azure>
2. Enter the subscription you want to onboard. You'll be redirected to Microsoft.
3. Sign in as a **tenant admin** and click **Accept** on the consent prompt.

> **Already consented this tenant before?** Skip to Step 2 — subsequent subscriptions don't need a new consent.

Verify the service principal landed in your tenant (replace the app id with the one shown in the LumiTure wizard):

```bash
read -p "LumiTure App (client) ID from the wizard: " LUMITURE_APP_ID
az ad sp show --id "${LUMITURE_APP_ID}" --query "{name:displayName, objectId:id}" -o table
```

If you see a name + objectId, consent succeeded. Click **Next**.

## Step 2 — Run it

Review what the script will do first:

```bash
cat onboard-wrapper.sh
```

Then run it. If you opened this from the LumiTure wizard, your session token is already set, so a bare run does everything — no values to type:

```bash
bash onboard-wrapper.sh
```

The wrapper **auto-detects** your subscription (when you have exactly one) and picks a default export storage account + resource group, creating them if needed. To target a specific subscription or storage account, pass them explicitly:

```bash
bash onboard-wrapper.sh <SUBSCRIPTION_ID> [STORAGE_ACCOUNT] [RESOURCE_GROUP]
```

What the script does:
1. Confirms LumiTure's SP is consented (Step 1)
2. Ensures the storage account + `billing-export` container exist, with a 180-day lifecycle rule that auto-deletes old export blobs (keeps storage cost flat; `--no-retention` to skip)
3. Grants `Cost Management Reader` + `Storage Blob Data Reader`, plus (default) the `LumiTure FinOps Reader` role for usage/rightsizing data — pass `--no-usage` for a minimal billing-only grant
4. Creates a daily **ActualCost** export (plus a **FOCUS** export by default; `--no-focus` to skip) rooted at `cost/`, **and** wires the Event Grid subscription that streams new export blobs to LumiTure (the data path)
5. Registers the connection with LumiTure automatically when launched from the wizard, or prints the JSON form values for you to paste in otherwise

You'll see ✅ checkmarks as each step succeeds.

> **Not launched from the wizard?** The data path (step 4's Event Grid subscription) and auto-registration (step 5) need your LumiTure session token. Either open this flow from the LumiTure Azure wizard (which sets it for you) or `export LUMITURE_JWT=<your session token>` before running. Without it the grants + export are still created, but billing data won't flow until the connection is finished in the wizard.

## Step 3 — Finish in LumiTure

If you ran with your session token (launched from the wizard), the connection is already registered — skip to Step 4. Otherwise the script prints:

```json
{
  "tenant_id": "...",
  "subscription_id": "...",
  "storage_account": "...",
  "container": "billing-export"
}
```

Open the LumiTure Azure wizard:

> <https://app.lumiture.ai/authorization/billing-integration/azure>

Enter the values and submit. The subscription status moves to `IN_PROGRESS`, then `CONNECTED` once LumiTure's subscription sync runs.

## Step 4 — When does data appear?

- **Connection** (CONNECTED): once the subscription sync runs after submit.
- **Cost data**: Azure's first daily export run lands within ~24h, then LumiTure transfers blob → BigQuery on its schedule. Rows also restate over ~30 days as Azure finalizes cost.

So the connection is near-immediate; populated dashboards follow within a day.

## Cleanup / revoke

Nothing was installed on your computer. To revoke later:

```bash
# remove the role grants
az role assignment delete --assignee "${LUMITURE_APP_ID}" --scope "/subscriptions/${SUBSCRIPTION_ID}"
# delete the export
az costmanagement export delete --name daily-actual-cost --scope "subscriptions/${SUBSCRIPTION_ID}"
```

---

**Issues?** File at <https://github.com/CloudMile-Product/lumiture-cloud-onboard/issues> or contact your LumiTure rep.
