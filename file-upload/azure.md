# Azure — export actual cost and FOCUS cost

Create **two** exports with the steps below, one of each type, at the **same scope**, and send the files of both: **Cost and usage details (actual)** (not amortized) and **Cost and usage details (FOCUS)**. The FOCUS limits in the next paragraph apply to the FOCUS export only.

**Check your billing account type first.** LumiTure currently reads the actual-cost file of a **Microsoft Customer Agreement (MCA)** billing account. An Enterprise Agreement (EA) or pay-as-you-go export uses different column names, and its costs would not load. If you are on EA or pay-as-you-go, check with LumiTure before exporting.

Run on the **subscription**, or on a billing scope that covers all the subscriptions you want to send (a resource-group export covers only that resource group) (EA enrollment / department / account, MCA billing account / profile / invoice section). **Management group scope is not supported for FOCUS exports**, and pay-as-you-go (MOSP) subscriptions don't support FOCUS ([Microsoft](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports)). For several subscriptions, use a billing-account-level export, or one export per subscription. Some pay-as-you-go sign-ups are on an MCA billing account; check your billing account type in the portal.

## Before you start

- **Permissions.** Creating exports needs **Owner** or **Contributor** on the scope (a Contributor manages only the exports they created) and write permission on the destination storage account. To download the exported files afterwards you also need read access to the blobs (for example **Storage Blob Data Reader**, or the account key if shared-key access is allowed) ([Microsoft](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports#prerequisites)).
- **Storage account.** In **your own tenant**. If it has a firewall, turn on **Allow trusted Azure services access**, give the export's managed identity **Storage Blob Data Contributor** (Azure scopes it to the destination container when you can assign roles), and, if you create the export through the REST API, use API version **2023-08-01 or later** (the portal handles this for you). The person who creates the export must be able to assign roles on the storage account (**Owner**, or a custom role with `Microsoft.Authorization/roleAssignments/write`). If it disallows shared-key access the export writes through that managed identity as well, and with no role it produces nothing without an obvious error: check the export's run history.
- **First export in a subscription.** Azure may answer the first create with a "resource provider registration in progress" error; wait a minute and retry.

## Steps

1. Open **Cost Management → Exports → Create**.
2. Type **Cost and usage details (actual)** for the first export and **Cost and usage details (FOCUS)** for the second; format **CSV** (gzip optional; send CSV, not Parquet), daily export. Give the two exports different names so their folders do not mix.
3. Choose the destination storage account and container.
4. Run the export. Each run is written to `<directory>/<export name>/<YYYYMMDD-YYYYMMDD>/<run ID>/` as several partitions (for example `part_0_0001.csv`, `part_0_0002.csv`) plus a `manifest.json` that lists them. The data is only complete with **every partition**: download everything from one completed run, and send all the partitions and the manifest with [`upload.sh`](upload.sh).

## Past months

On the export, choose **Export selected dates** to re-run it for a past month: one month at a time, up to 13 months in the portal (older through the Exports Execute REST API). Daily exports are month-to-date, so for each closed month send the **latest completed run for that month**. Azure runs the previous month's export again during the first days of a month to include late charges, so send a month after about day 5 of the following month.
