# LumiTure AWS Onboarding — CloudFormation template

Declarative alternative to the bash / CloudShell flow. Same end state:
- a customer-managed policy (`LumiTureIntegrationPolicy`) matching **exactly** the document LumiTure's permission check validates
- a cross-account role (`LumiTureIntegrationRole`) trusting `arn:aws:iam::536697256548:root` with your ExternalId (no MFA condition)
- stack **Outputs** = the four wizard form values (`AccountId`, `RoleArn`, `PolicyArn`, `ExternalId`)

Run it in the **Organization management (payer) account** — same rule as the script. The optional usage integration (member-account monitoring StackSet) is separate; see [`../README.md`](../README.md#usage-integration-optional).

CloudFormation cannot make the script's Organization-management-account preflight check. Before deploying, run:

```bash
aws sts get-caller-identity --query Account --output text
aws organizations describe-organization --query 'Organization.MasterAccountId' --output text
```

The two account IDs must match. `AWSOrganizationsNotInUseException` is also acceptable for a standalone account.

## Three ways to deploy

### 1. Quick-create link (one-click — pending template hosting)

A CloudFormation quick-create URL needs the template served from S3. Once LumiTure publishes this file to its public template bucket, the link looks like:

```
https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate
  ?templateURL=https%3A%2F%2Flumiture-stackset-template.s3.us-east-1.amazonaws.com%2Fbilling_role_template.yaml
  &stackName=lumiture-billing-access
  &param_ExternalId=<the ExternalId from the wizard>
```

> ⚠️ **Pending hosting** — `billing_role_template.yaml` is not yet published to the bucket, so this link is not live. Use one of the two paths below; they work today from this repo.

### 2. Console upload

AWS Console → **CloudFormation → Create stack → Upload a template file** → pick `billing-role.yaml` from this directory → fill in `ExternalId` → acknowledge the IAM-resources capability → create. Read the four values off the stack's **Outputs** tab.

### 3. CLI

```bash
aws cloudformation create-stack \
  --stack-name lumiture-billing-access \
  --template-body file://billing-role.yaml \
  --parameters ParameterKey=ExternalId,ParameterValue=<the ExternalId from the wizard> \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

aws cloudformation wait stack-create-complete --stack-name lumiture-billing-access --region us-east-1
aws cloudformation describe-stacks --stack-name lumiture-billing-access --region us-east-1 \
  --query 'Stacks[0].Outputs' --output table
```

All paths end the same way: enter the Outputs into the [LumiTure AWS wizard](https://app.lumiture.ai/authorization/billing-integration/aws) (or let `../init.sh` auto-submit with a session token).

## Notes

- **The policy document is an exact-match contract.** LumiTure compares the live policy to its expected document with strict equality — statement order, every action, and even `Resource: "*"` (string) vs `Resource: ["*"]` (one-element list) are significant. Do not edit or "normalize" the `PolicyDocument` in `billing-role.yaml`; a cosmetic change makes the permission check fail with a policy-configuration error.
- The stack region doesn't matter for IAM (global), but LumiTure's exports and buckets live in **us-east-1** — keep the examples' region as-is.
- Re-running: the stack is idempotent via CloudFormation updates. If you created the role/policy with `../init.sh` first, **don't** also create this stack (the names collide); the script and the template are alternatives, not layers.
- Deleting the stack removes the role + policy and disconnects LumiTure — do it only after unlinking the integration in the app.
