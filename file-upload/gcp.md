# GCP — export billing + pricing as Avro

Send **two** datasets: the detailed usage cost export and the pricing export, both as Avro. A FOCUS file is not requested for GCP.

## Before you start

- **Detailed usage cost** export to BigQuery is enabled (table `gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID>`; the billing account ID in the table name uses underscores, not dashes).
- **Pricing** export to BigQuery is enabled (table `cloud_pricing_export`).
- **History.** How much billing history exists depends on the dataset location ([Google](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery)). When the export is first enabled, a **multi-region (EU/US)** dataset is backfilled from the start of the *previous month*; a single-region dataset starts **on the day the export was enabled**. An export that has been running for a while already holds the months accumulated since. A new export can take up to five days to finish backfilling, and re-enabling an export does not backfill again, so wait before exporting a month right after enabling it. **Google does not backfill pricing**: there is no pricing data from before the day it was enabled. Tell LumiTure your dataset location and both enable dates before exporting. Enabling either export is Console-only ([Google docs](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup)).
- **Permissions** (typically): the account that runs the SQL needs to run BigQuery jobs (`bigquery.jobs.create`) and read the export dataset, and needs write (create object) permission on a Cloud Storage bucket in the **same location** as the dataset; for the download step it also needs permission to list and read the objects in that bucket.

## Export to Avro in your own bucket

Run the SQL in the BigQuery console, or with `bq query --use_legacy_sql=false --location=DATASET_LOCATION` (for example `US` or `EU`; `bq` assumes `US` if you leave it out). Replace `PROJECT`, `DATASET`, `BILLING_ACCOUNT_ID`, `YOUR_BUCKET`, and use a **new, empty `RUN_DATE` folder for every run** (for example today's date): an export can leave files from an earlier run in a reused folder, and you would then upload them ([Google](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/export-statements)). Keep every column (`SELECT *`) and use Avro logical types.

```sql
EXPORT DATA OPTIONS (
  uri = 'gs://YOUR_BUCKET/lumiture/RUN_DATE/billing/billing-*.avro',
  format = 'AVRO',
  use_avro_logical_types = true
) AS
SELECT * FROM `PROJECT.DATASET.gcp_billing_export_resource_v1_BILLING_ACCOUNT_ID`
WHERE usage_start_time >= TIMESTAMP('YYYY-MM-DD')   -- first day to send
  AND usage_start_time <  TIMESTAMP('YYYY-MM-DD')   -- first day NOT to send
ORDER BY export_time, usage_start_time;            -- usually fewer files, not guaranteed
```

The `billing-` and `pricing-` file prefixes keep the two datasets apart: each file goes to its own upload URL, so do not mix them up.

**Scan cost.** The billing table is also day-partitioned by ingestion time (check `timePartitioning` with `bq show`, as for pricing), so the `usage_start_time` filter alone still scans all of it. To scan less, add a `_PARTITIONTIME` predicate that starts at the first day to send and ends about a week after the last day to send (a row lands in the partition of the day it was ingested, which can be later than its usage day), and keep the `usage_start_time` filter.

### How many files you get

BigQuery may write an export as many files, and each file is a separate upload. `ORDER BY` usually reduces the count (in one small test, a month of billing came out as hundreds of files without it and as a single file with it) but Google documents an ordered export across multiple files and promises no count. Check the count before asking for URLs. For a very large billing table the sort can fail with a "Resources exceeded" error: then export one day or one week at a time, or drop the `ORDER BY` and accept more files.

### The pricing export is large

The pricing table is day-partitioned and holds a price-list snapshot per day, so it can reach many GB. Check its size: `bq show --format=prettyjson PROJECT:DATASET.cloud_pricing_export` (`numBytes`). Ask LumiTure how many days of pricing to send, then filter by partition:

- If `timePartitioning` in that output has **no `field`**, the table is ingestion-time partitioned: filter on `_PARTITIONTIME`. A filter on `export_time` then scans the whole table.
- If it has a `field`, filter on that column instead.

```sql
EXPORT DATA OPTIONS (
  uri = 'gs://YOUR_BUCKET/lumiture/RUN_DATE/pricing/pricing-*.avro',
  format = 'AVRO', use_avro_logical_types = true
) AS
SELECT * FROM `PROJECT.DATASET.cloud_pricing_export`
WHERE _PARTITIONTIME >= TIMESTAMP('YYYY-MM-DD')   -- first day to send
  AND _PARTITIONTIME <  TIMESTAMP('YYYY-MM-DD');  -- first day NOT to send
```

## Download and send

Download into a **fresh local folder** (`gcloud storage cp -r gs://YOUR_BUCKET/lumiture/RUN_DATE ./RUN_DATE`), then send each `billing-*.avro` and `pricing-*.avro` file with [`upload.sh`](upload.sh), each to its own URL.

## For a recurring feed

Agree the window with LumiTure first. Billing rows can arrive late ([Google](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables)) and pricing gains a new daily snapshot each day, so a plain "rows since the last send" can both miss and repeat data. Send pricing by day partition.
