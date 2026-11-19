# AWS — export FOCUS 1.0

Run in the **Organization management (payer) account**, or in a standalone account, in `us-east-1` (billing exports live there).

## Console route

1. Open **Billing and Cost Management → Data Exports → Create export**.
2. Type **Standard data export**, table **FOCUS 1.0 with AWS columns** (SQL table `FOCUS_1_0_AWS`).
3. Format **Parquet** (or GZIP CSV). The data in a FOCUS 1.0 export has **hourly** granularity only; selectable hourly, daily or monthly granularity starts with FOCUS 1.2 ([AWS](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-focus-1-2-migrating.html)). How often AWS refreshes the files is a separate matter, and the first delivery can take up to a day after you create the export. AWS can also restate the previous billing period for up to two weeks after it ends, so send a month only once it is final. Stay on 1.0 unless LumiTure tells you it accepts 1.2.
4. Choose an S3 bucket **in your own account** (keep it private) and choose to **overwrite** the existing export file rather than create a new file each time, then create the export. If the bucket uses a customer-managed KMS key, its key policy must allow the Data Exports service, or delivery fails.
5. Download **every file of each delivered period** (the data files plus the manifest) from your bucket and send them with [`upload.sh`](upload.sh).

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

2. Get the example request and create the export. In CloudShell, `git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git` and use `file-upload/aws-export.example.json`, or download it:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/file-upload/aws-export.example.json
   # edit YOUR_BUCKET (and the name and prefix if you like), then:
   aws bcm-data-exports create-export --region us-east-1 --export file://aws-export.example.json
   ```

   The request uses table `FOCUS_1_0_AWS`, Parquet, `OVERWRITE_REPORT` and `SYNCHRONOUS`. The CLI rejects `SELECT *`, so the example lists the FOCUS 1.0 columns explicitly; the console fills them in for you.

## What a delivered export looks like

`<prefix>/<export name>/data/billing_period=YYYY-MM/<name>-00001.snappy.parquet`, plus `<prefix>/<export name>/metadata/billing_period=YYYY-MM/` holding `…-Manifest.json` files (`<prefix>` is the S3 prefix you set; the example request uses `focus`). Keep the lowercase `billing_period=` spelling in mind when you look for them: S3 key names are case-sensitive. A month can have several data files: send **all** of them and the manifest, and tell LumiTure which month each belongs to.

## Past months

A new export may not contain earlier months. If you already run a FOCUS 1.0 export, send its existing files. Otherwise **check with LumiTure before creating one**.

## Quota

AWS caps an account at 2 FOCUS exports (`Account has reached the resource limit of 2 on FOCUS_1_0_AWS table`); check you have a free slot.

## Permissions

The person running the CLI route needs these actions (shown on `Resource: "*"` for brevity; scope the S3 actions to the destination bucket and its objects, and the Data Exports actions to the export where AWS supports it):

| Action | Needed when |
|---|---|
| `bcm-data-exports:CreateExport` | creating the export |
| `cur:PutReportDefinition` | creating a FOCUS export: `CreateExport` fails with `AccessDeniedException ... cur:putReportDefinition` without it |
| `bcm-data-exports:ListExports`, `bcm-data-exports:GetExport` | checking existing exports, quota and status |
| `s3:CreateBucket`, `s3:PutBucketPolicy`, `s3:PutBucketPublicAccessBlock` | only if you create and configure the destination bucket yourself |
| `s3:ListBucket`, `s3:GetObject` | only to download the delivered files |

The console route may need more (table and bucket discovery, billing console access). If you hit an access error, ask your administrator.
