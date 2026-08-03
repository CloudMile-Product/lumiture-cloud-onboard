# LumiTure AWS Onboarding — CloudShell / CloudFormation

> 繁體中文（IT SOP）：[`README.zh-TW.md`](README.zh-TW.md)

> Guided onboarding for [LumiTure](https://app.lumiture.ai): the customer creates a cross-account IAM role that lets LumiTure set up the AWS billing exports — in their own AWS identity, zero install. The AWS analog of the [GCP Cloud Shell flow](../gcp/README.md) and the [Azure flow](../azure/README.md).

## How the AWS flow differs from GCP/Azure

| | GCP | Azure | AWS |
|---|---|---|---|
| Customer grant | IAM on existing BQ export | Admin-consent + RBAC roles | **Cross-account IAM role + ExternalId** |
| Who provisions the pipeline | Customer (export pre-exists) | Customer (script creates export) | **LumiTure** — it assumes the role and creates the buckets + exports itself |
| One un-scriptable step | Enable billing export (Console) | Admin consent (browser) | — none — |
| Native shell | Google Cloud Shell (badge) | Azure Cloud Shell | **AWS CloudShell** (no auto-clone — `git clone` in Step 0) |
| IaC vehicle | Terraform (`../gcp/terraform/`) | Bicep (`../azure/bicep/`) | **CloudFormation** (`cloudformation/`) |

Because the customer only creates a role + policy (LumiTure provisions the rest), this is the lightest kit of the three — but the grant is **not purely read-only**: the policy allows S3 writes and billing-export management, restricted to two dedicated `lumiture-<account>-cur/-focus` buckets. See [What LumiTure can and cannot do](#what-lumiture-can-and-cannot-do).

## Try it

> ⚠️ **Run this in the Organization management (payer) account.** Member accounts are refused — both by this script and by LumiTure's backend — because onboarding a member account as if it were the payer has historically corrupted billing data. Standalone accounts (no Organization) work fine.

1. Open **AWS CloudShell**: <https://console.aws.amazon.com/cloudshell/> (any region)
2. Clone + enter:
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/aws
   ```
3. Run the script:
   ```bash
   ./init.sh
   ```

Every argument defaults correctly for production: **role** = `LumiTureIntegrationRole`, **policy** = `LumiTureIntegrationPolicy`, **ExternalId** = reused from an existing role / fetched with your session token / generated, **LumiTure API** = prod.

4. Enter the printed form values into the [LumiTure wizard](https://app.lumiture.ai/authorization/billing-integration/aws) to finish — or pass `--lumiture-jwt <token>` and the script submits them for you (permission check + integrate, with automatic retry on IAM propagation delay).

## What's in this directory

| File | Purpose |
|---|---|
| `init.sh` | **The onboarding script — run this.** Management-account gate + quota check + policy/role create + structural self-check + form-value output |
| `onboard-wrapper.sh` | Interactive wrapper around `init.sh` (confirm prompt, positional args) |
| `tutorial.md` | Step-by-step CloudShell walkthrough (**optional** — `init.sh` is self-contained) |
| `cloudformation/` | CloudFormation template — declarative alternative (same role + policy, wizard values as stack Outputs). See `cloudformation/README.md`. |

**Two ways to run the grant:** the **bash / CloudShell** flow above (zero-install, customer-driven) or the **CloudFormation template** in `cloudformation/` (for teams that prefer IaC / review-then-apply). Both create the same role + policy and emit the same wizard form values. They are alternatives — don't run both (the resource names collide).

## What it does

1. **Management-account gate:** refuses member accounts (see [Try it](#try-it)); standalone accounts pass with the usage StackSet skipped
2. **Quota headroom:** AWS caps an account at 5 CUR / 2 FOCUS billing exports and LumiTure adds one of each — the script counts existing exports and fails early instead of letting LumiTure's quota check fail later
3. Creates the customer-managed policy — the **exact document LumiTure validates** (strict equality; the script never "improves" it) — and updates it in place if a previous version drifted
4. Creates the cross-account role trusting `arn:aws:iam::536697256548:root` (LumiTure's account — public by design, like the GCP service-account email) with your **ExternalId**, no MFA condition, and attaches the policy
5. **(opt-in, `--with-usage`)** Deploys LumiTure's member-account monitoring StackSet — see [Usage integration](#usage-integration-optional)
6. **Verifies the result (Phase 5)** by reading the live state back: trust principal + ExternalId, policy attached, policy document strictly equal to the expected one. See [Failures are fatal](#failures-are-fatal)
7. Prints the form values (or auto-submits with `--lumiture-jwt`: permission check → integrate → usage)

Zero install on the customer's machine. Auth stays in the customer's AWS identity. LumiTure never sees the customer's credentials — it only ever assumes the role you created, gated by the ExternalId.

## What LumiTure can and cannot do

The policy is scoped for one job: managing the billing-data pipeline.

| Can | Cannot |
|---|---|
| Create/manage billing exports (`bcm-data-exports`, `cur`) | Read or touch any workload (no EC2/S3/RDS data access) |
| Create + write the two dedicated `lumiture-<account>-cur/-focus` buckets | Write to **any other** S3 bucket (resources pinned by ARN) |
| List Organization accounts, read account aliases, read its own role/policy | Modify IAM, create users, escalate |
| Read CloudWatch metrics + EC2 instance *metadata* (usage integration) | Start/stop/change anything |

## Usage integration (optional)

Rightsizing/usage data needs a read-only monitoring role in **every member account**, deployed via LumiTure's CloudFormation **StackSet** (service-managed, auto-deploys to new accounts). `--with-usage` (or `WITH_USAGE=1` for the wrapper) automates it:

1. Enables **CloudFormation StackSets trusted access** on the Organization (one-time, org-wide — the reason this is opt-in rather than default)
2. Creates the StackSet **from LumiTure's hosted template URL** — LumiTure byte-compares the deployed template against its hosted copy, so the script never uses a local file
3. Deploys stack instances to the org root (or `--ou-ids` to narrow), waits, and fails the run if more than half the instances failed (LumiTure's own threshold)
4. Submits `stackset_name` / `role_name` / usage `external_id` after the billing integration succeeds — the usage ExternalId is a **separate value** from the billing one

Billing must connect first; usage can always be added later from the [usage wizard](https://app.lumiture.ai/authorization/usage-integration/aws).

> **Re-running with an existing StackSet:** the ExternalId parameter is write-only (NoEcho) — the script can't read it back. Keep the value from the run that created the StackSet, or pass `--usage-external-id` to match it.

## Failures are fatal

Anything that would leave the integration half-wired — a drifted policy document, a missing attachment, a trust policy without the ExternalId, a mostly-failed StackSet — is collected, and the script **exits non-zero listing each problem** (and skips auto-submit). A green `AWS onboarding complete` means the structure was read back and checked, not merely that the script reached the end.

Phase 5 deliberately verifies **structure, not data**: LumiTure provisions the exports at submit time and AWS's first daily run lands ~24h later. Data covers **integration time onward — no backfill** — so confirm the dashboard tomorrow, not today.

> **The #1 rejection cause is a policy that doesn't exactly match.** LumiTure compares documents with strict equality — a reordered statement or a hand-added action fails the permission check. If you customized the policy, re-run `./init.sh` to rewrite it.

## License

MIT — see [`../LICENSE`](../LICENSE).
