# File upload — fallback when you cannot grant access

> 繁體中文（IT SOP）：[`README.zh-TW.md`](README.zh-TW.md)

> **Preview.** LumiTure confirms the scope, the file list and the upload method with you before you start. Contact your LumiTure representative first.

The guided flows ([`gcp/`](../gcp/), [`azure/`](../azure/)) need you to **grant LumiTure access** to your billing data. If your security policy does not allow that, use this path instead: **you export the billing files yourself, in your own identity, and send them to LumiTure.** Nothing is granted, and LumiTure never reads your cloud.

Use it for a **one-time import** of past months, or, if you can keep sending files, a **recurring feed**.

## How it works

1. **Export** the billing files in your own cloud, following the guide for each cloud below.
2. **Tell LumiTure** which files you have (names and sizes, per cloud and month).
3. **LumiTure sends you one upload URL per file.** A URL is valid for one file name and expires, so it can only be issued once the file list is known.
4. **Upload** each file to its URL with [`upload.sh`](upload.sh).

## What to export

| Cloud | Export | Format | Guide |
|---|---|---|---|
| AWS | **CUR 2.0** and **FOCUS 1.0** exports (Data Exports) | Parquet or CSV (gzip) | [`aws.md`](aws.md) |
| Azure | **Cost and usage details (actual)** and **FOCUS** cost exports (Cost Management); actual cost is read from MCA billing accounts today, see [`azure.md`](azure.md) | CSV (gzip optional) | [`azure.md`](azure.md) |
| GCP | **Detailed usage cost** and **Pricing** BigQuery exports (not a FOCUS file) | Avro | [`gcp.md`](gcp.md) |

For GCP send the two BigQuery exports, not a FOCUS file. Avro (not CSV) keeps nested columns such as `labels`, `credits` and `project`. Resource utilization (rightsizing) data is **not** part of this path; the detailed usage cost export above is billing data and is included.

## Before you start

- **Permissions.** Each guide lists what the person running it needs. Ask your cloud administrator early: creating exports, buckets and role assignments is often restricted.
- **History.** How many past months exist depends on the cloud: a new AWS export may not contain earlier months; Azure can re-run an export for up to 13 past months in the portal; when a GCP billing export is first enabled it is backfilled to the start of the previous month (multi-region dataset) or starts on the enable day (single region), so an export that has been running for a while already holds older months (a new one can take up to five days to finish backfilling), and GCP pricing is never backfilled. Check with LumiTure what you can supply before you export.
- **When a month is ready.** Cloud exports restate a month until it closes (Azure and AWS files are month-to-date, GCP rows can arrive late). Send a month once it has closed and your invoice is final, and send each period once. Tell LumiTure before you resend anything, because a resent file can be loaded twice.
- **Where to run it.** The scripts need `bash` and `curl`. On Windows, use AWS CloudShell, Azure Cloud Shell or Google Cloud Shell.

## Get the upload script

In AWS CloudShell, Azure Cloud Shell, Google Cloud Shell or any Linux or macOS shell:

```bash
git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/file-upload
```

or download just the script and make it executable:

```bash
curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/file-upload/upload.sh && chmod +x upload.sh
```

Then run it as `./upload.sh <file>` from that folder.

## How to send

LumiTure gives you the details privately; nothing about LumiTure's storage is published in this repo.

1. **Upload URL (quickest).** LumiTure sends a signed URL that allows an **upload** only and **expires**. Run `./upload.sh <file>` and paste the URL when prompted: the script never takes the URL as an argument, so it stays out of your shell history and the process list. To script it, pipe the URL in: `printf '%s' "$URL" | ./upload.sh <file>`. Treat the URL as a password until it expires. Whether a URL can be reused or overwrite an existing file depends on the cloud and how it was signed: an S3 presigned PUT URL and an Azure SAS URL with write permission can, a GCS signed URL for an identity that only has `roles/storage.objectCreator` cannot. A URL signed with headers (for example `Content-Type`) needs the same headers passed to `upload.sh` as extra arguments. A single upload is one HTTP PUT, so tell LumiTure the file sizes first; very large files may need another method.
2. **Your own service account or identity (for a recurring feed).** You create a new identity in your cloud and send LumiTure its address; LumiTure can grant it upload access to a LumiTure location. This is simplest on GCP. On AWS and Azure it needs a cross-cloud identity and is more involved: ask LumiTure.

## Files here

| File | Purpose |
|---|---|
| [`aws.md`](aws.md), [`azure.md`](azure.md), [`gcp.md`](gcp.md) | How to produce the files |
| [`aws-export.example.json`](aws-export.example.json) | A complete AWS Data Exports request to copy (FOCUS 1.0) |
| [`aws-cur2-export.example.json`](aws-cur2-export.example.json) | The same for CUR 2.0 |
| [`upload.sh`](upload.sh) | Uploads one file to a signed URL. Embeds no credentials; the URL is the credential |
