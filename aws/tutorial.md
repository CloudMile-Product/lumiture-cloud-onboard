# LumiTure AWS Onboarding — CloudShell Walkthrough

<!--
  AWS CloudShell has no guided-tutorial renderer (unlike Google Cloud Shell),
  so this is a plain step-by-step document — Step 0 clones the repo, same
  pattern as the Azure walkthrough.
-->

Welcome 👋 This walkthrough connects your AWS billing data to LumiTure. Everything runs in AWS CloudShell — no install on your computer.

You'll:
1. Confirm you're in the Organization **management (payer) account**
2. Create an IAM policy + cross-account role that lets LumiTure set up the billing exports
3. Get the four values to enter in LumiTure's wizard (or auto-submit them)

Unlike GCP/Azure, you don't provision any data pipeline: LumiTure assumes the role you create here and sets up the S3 buckets + billing exports itself. The role's S3 write access is restricted to two dedicated `lumiture-<your-account>-cur/-focus` buckets — nothing touches your workloads.

## Step 0 — Open CloudShell and get this repo

Open **AWS CloudShell** from the console (the `>_` icon in the top bar) or <https://console.aws.amazon.com/cloudshell/>. Any region works — the script pins `us-east-1` where it matters (that's where AWS billing exports live).

> ⚠️ Sign in to the **Organization management (payer) account** — the one that owns the consolidated bill. Onboarding a member account is refused (the script checks), because member-account exports can't see the whole Organization's costs.

CloudShell already has `aws` (v2), `jq`, and `git`, and uses your console identity. Clone this repo:

```bash
git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/aws
```

Confirm you're in the right account:

```bash
aws sts get-caller-identity
aws organizations describe-organization --query 'Organization.{Id:Id, ManagementAccount:MasterAccountId}'
```

`ManagementAccount` must equal your `Account` from the first command. (An `AWSOrganizationsNotInUseException` is fine too — a standalone account onboards normally, minus the usage StackSet.)

## Step 1 — Run it

Review what the script will do first:

```bash
cat onboard-wrapper.sh
```

Then run it. If you opened this from the LumiTure wizard, your session token is already set, so a bare run does everything — no values to type:

```bash
bash onboard-wrapper.sh
```

To pin the ExternalId shown in the wizard (or custom role/policy names), pass them explicitly:

```bash
bash onboard-wrapper.sh <EXTERNAL_ID> [ROLE_NAME POLICY_NAME]
```

What the script does:
1. Confirms this is the management account and that there's export-quota headroom (AWS caps an account at 5 CUR / 2 FOCUS exports; LumiTure adds one of each)
2. Creates the `LumiTureIntegrationPolicy` IAM policy — the exact document LumiTure validates
3. Creates the `LumiTureIntegrationRole` cross-account role trusting LumiTure's account with your ExternalId, and attaches the policy
4. Reads everything back and verifies it structurally (a drifted policy or missing attachment fails the run loudly)
5. Registers the integration with LumiTure automatically when launched from the wizard, or prints the JSON form values for you to paste in otherwise

You'll see ✅ checkmarks as each step succeeds.

> **Want usage/rightsizing data too?** Run with `WITH_USAGE=1 bash onboard-wrapper.sh` — it additionally deploys LumiTure's member-account monitoring StackSet (a read-only role in every member account). This is opt-in because it enables **org-wide CloudFormation StackSets trusted access** and touches every member account. See [Usage integration](README.md#usage-integration-optional) before enabling.

## Step 2 — Finish in LumiTure

If you ran with your session token (launched from the wizard), the integration is already registered — skip to Step 3. Otherwise the script prints:

```json
{
  "billing": {
    "account_id": "...",
    "role_arn": "arn:aws:iam::...:role/LumiTureIntegrationRole",
    "policy_arn": "arn:aws:iam::...:policy/LumiTureIntegrationPolicy",
    "external_id": "..."
  }
}
```

Open the LumiTure AWS wizard:

> <https://app.lumiture.ai/authorization/billing-integration/aws>

Enter the values, click **Check Permission** (must pass first), then **Integrate**. On submit, LumiTure assumes the role and provisions the two S3 buckets + billing exports in your account — that call can take a minute.

> A permission check right after creating the role can fail once due to IAM propagation delay (10–60s). The script's auto-submit retries this automatically; in the wizard, just click **Check Permission** again.

## Step 3 — When does data appear?

- **Connection**: within seconds of the Integrate call succeeding.
- **Cost data**: AWS's first daily export run lands within ~24h. Data covers **integration time onward — there is no backfill**, so don't expect historical months.

## Cleanup / revoke

Nothing was installed on your computer. To revoke later, unlink the integration in the LumiTure app first (that removes the exports + bucket wiring), then:

```bash
aws iam detach-role-policy --role-name LumiTureIntegrationRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LumiTureIntegrationPolicy
aws iam delete-role --role-name LumiTureIntegrationRole
aws iam delete-policy --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LumiTureIntegrationPolicy
# the two export buckets LumiTure created (empty them first if you want them gone):
aws s3 rb s3://lumiture-<ACCOUNT_ID>-cur --force
aws s3 rb s3://lumiture-<ACCOUNT_ID>-focus --force
```

---

**Issues?** Contact your LumiTure rep.
