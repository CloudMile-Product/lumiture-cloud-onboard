# LumiTure Cloud Onboarding

> Guided, low-install, customer-driven onboarding flows that grant [LumiTure](https://app.lumiture.ai) **read-only** access to a customer's cloud **billing/cost data** — each on that cloud's own native surface, in the customer's own identity. LumiTure never sees the customer's credentials.

This repo holds **one sibling flow per cloud**. They share a consistent shape (a guided entry point + the same "form values" contract the in-product wizard expects) but each runs on its cloud's native surface — we deliberately do **not** couple three credential ceremonies into one apply. See the [decision record](#design-decision).

## Clouds

| Cloud | Folder | Native surface | Customer grant | IaC | Status |
|---|---|---|---|---|---|
| **GCP** | [`gcp/`](gcp/) | Google Cloud Shell ([badge](gcp/README.md#try-it)) | IAM on existing BQ export | Terraform | ✅ Live |
| **Azure** | [`azure/`](azure/) | Azure Cloud Shell + browser admin-consent | Admin-consent + Cost Management Reader + Storage Blob Data Reader | Bicep | 🧪 POC |
| **AWS** | — | CloudFormation Launch-Stack / AWS CloudShell | Cross-account IAM role (+ ExternalId) | CloudFormation | ⬜ Planned |

Start with the per-cloud README:
- **[`gcp/README.md`](gcp/README.md)** — "Open in Cloud Shell" badge → guided grant
- **[`azure/README.md`](azure/README.md)** — open Azure Cloud Shell → clone → guided grant

## Why per-cloud, not one unified apply

Each cloud's grant is structurally different (GCP IAM on a BQ dataset; Azure admin-consent + RBAC + a cost export; AWS a cross-account role), runs on a different native surface, and lands data through a different path. Forcing them into a single Terraform apply or one Cloud Shell run would couple three independent credential ceremonies and forfeit the zero-credential property each native shell provides.

**What is shared** is the *packaging and contract*, not the execution: a consistent variable/output shape per cloud, and a parallel same-shaped onboarding flow.

## License

MIT — see [`LICENSE`](LICENSE).
