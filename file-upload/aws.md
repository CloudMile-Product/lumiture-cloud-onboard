# AWS — export CUR 2.0 and FOCUS 1.0

Run in the **Organization management (payer) account**, or in a standalone account, in `us-east-1` (billing exports live there).

Create **two** exports and send the files of both:

| Export | Table (SQL name) | Settings |
|---|---|---|
| **CUR 2.0** | `COST_AND_USAGE_REPORT` | **Include resource IDs** on, **Split cost allocation data** on, time granularity **Hourly**, **every column** |
| **FOCUS 1.0** | FOCUS 1.0 with AWS columns (`FOCUS_1_0_AWS`) | **every column** (hourly is the only granularity) |

**Keep every column.** A column you deselect is not rejected: it arrives empty, and the reports that use it stay blank. Leave other optional settings off unless LumiTure asks for them.

## Console route

Do these steps twice, once per export in the table above.

1. Open **Billing and Cost Management → Data Exports → Create export**.
2. Type **Standard data export**, and choose the table: **CUR 2.0**, or **FOCUS 1.0 with AWS columns**.
3. Set the table settings from the table above. For FOCUS 1.0 the data has **hourly** granularity only; selectable granularity starts with FOCUS 1.2 ([AWS](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-focus-1-2-migrating.html)). Stay on FOCUS 1.0 unless LumiTure tells you it accepts 1.2.
4. Format **Parquet** (or GZIP CSV). The first delivery can take up to a day after you create the export. AWS can restate the previous billing period for up to two weeks after it ends, so send a month only once it is final.
5. Choose an S3 bucket **in your own account** (keep it private), give each export its own S3 prefix (for example `cur2` and `focus`), choose to **overwrite** the existing export file rather than create a new file each time, then create the export. If the bucket uses a customer-managed KMS key, its key policy must allow the Data Exports service, or delivery fails.
6. Download **every file of each delivered period** (the data files plus the manifest) from your bucket and send them with [`upload.sh`](upload.sh).

## CLI route

Replace `YOUR_BUCKET` with a new bucket name and `ACCOUNT_ID` with your 12-digit account ID (`aws sts get-caller-identity --query Account --output text`).

1. Create the bucket and attach a policy that lets the export service write to it. Save this as `policy.json`:

   ```json
   {"Version":"2012-10-17","Statement":[{
     "Sid":"EnableAWSDataExportsToWriteToS3AndCheckPolicy","Effect":"Allow",
     "Principal":{"Service":["bcm-data-exports.amazonaws.com","billingreports.amazonaws.com"]},
     "Action":["s3:PutObject","s3:GetBucketPolicy"],
     "Resource":["arn:aws:s3:::YOUR_BUCKET","arn:aws:s3:::YOUR_BUCKET/*"],
     "Condition":{"StringLike":{
       "aws:SourceAccount":"ACCOUNT_ID",
       "aws:SourceArn":["arn:aws:cur:us-east-1:ACCOUNT_ID:definition/*",
                        "arn:aws:bcm-data-exports:us-east-1:ACCOUNT_ID:export/*"]}}}]}
   ```

   ```bash
   aws s3api create-bucket --bucket YOUR_BUCKET --region us-east-1
   aws s3api put-public-access-block --bucket YOUR_BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
   aws s3api put-bucket-policy --bucket YOUR_BUCKET --policy file://policy.json
   ```

   The condition ARNs must contain your real account ID. A policy whose `aws:SourceArn` is malformed is accepted by S3, but creating the export then fails with `S3 bucket permission validation failed`.

2. Get the two example requests and create both exports. In CloudShell, `git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git` and use the files in `file-upload/`, or download them:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/file-upload/aws-cur2-export.example.json
   curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/file-upload/aws-export.example.json
   # edit YOUR_BUCKET in both (and the names and prefixes if you like), then:
   aws bcm-data-exports create-export --region us-east-1 --export file://aws-cur2-export.example.json
   aws bcm-data-exports create-export --region us-east-1 --export file://aws-export.example.json
   ```

   `aws-cur2-export.example.json` uses table `COST_AND_USAGE_REPORT` with `INCLUDE_RESOURCES`, `INCLUDE_SPLIT_COST_ALLOCATION_DATA` and `TIME_GRANULARITY=HOURLY`, prefix `cur2`. `aws-export.example.json` uses table `FOCUS_1_0_AWS`, prefix `focus`. Both use Parquet, `OVERWRITE_REPORT` and `SYNCHRONOUS`. The CLI rejects `SELECT *`, so the examples list every column explicitly; the console fills them in for you.

## What a delivered export looks like

| Export | Data files | Manifests |
|---|---|---|
| CUR 2.0 | `<prefix>/<export name>/data/BILLING_PERIOD=YYYY-MM/<export name>-00001.snappy.parquet` | `<prefix>/<export name>/metadata/BILLING_PERIOD=YYYY-MM/` |
| FOCUS 1.0 | `<prefix>/<export name>/data/billing_period=YYYY-MM/<export name>-00001.snappy.parquet` | `<prefix>/<export name>/metadata/billing_period=YYYY-MM/` |

`<prefix>` is the S3 prefix you set (`cur2` and `focus` in the example requests). Note the spelling: **uppercase** `BILLING_PERIOD=` for CUR 2.0, **lowercase** `billing_period=` for FOCUS; S3 key names are case-sensitive. A month can have several data files: send **all** of them and the manifest, and tell LumiTure which export and month each belongs to.

**File size.** Hourly CUR 2.0 with resource IDs is much larger than FOCUS. Tell LumiTure the size of every file before asking for upload URLs (see [How to send](README.md#how-to-send)).

## Past months

A new export may not contain earlier months. If you already run exports, you may be able to send their existing files: a CUR 2.0 export only if it has resource IDs, split cost allocation data and hourly granularity (a legacy Cost and Usage Report is not a substitute), and a FOCUS 1.0 export as is. Otherwise **check with LumiTure before creating new ones**.

## Quota

AWS limits each account to **5** CUR 2.0 exports and **2** FOCUS 1.0 exports ([AWS](https://docs.aws.amazon.com/cur/latest/userguide/dataexports-quotas.html)). Check you have a free slot for each (`Account has reached the resource limit of 2 on FOCUS_1_0_AWS table` means the FOCUS limit is reached).

## Permissions

The person running the CLI route needs these actions (shown on `Resource: "*"` for brevity; scope the S3 actions to the destination bucket and its objects, and the Data Exports actions to the export where AWS supports it):

| Action | Needed when |
|---|---|
| `bcm-data-exports:CreateExport` | creating the exports |
| `cur:PutReportDefinition` | creating a CUR 2.0 export ([AWS](https://docs.aws.amazon.com/cur/latest/userguide/bcm-data-exports-access.html)) or a FOCUS export: `CreateExport` fails with `AccessDeniedException ... cur:putReportDefinition` without it |
| `bcm-data-exports:ListExports`, `bcm-data-exports:GetExport` | checking existing exports, quota and status |
| `s3:CreateBucket`, `s3:PutBucketPolicy`, `s3:PutBucketPublicAccessBlock` | only if you create and configure the destination bucket yourself |
| `s3:ListBucket`, `s3:GetObject` | only to download the delivered files |

The console route may need more (table and bucket discovery, billing console access). If you hit an access error, ask your administrator.
