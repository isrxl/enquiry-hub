# Customer Enquiry Hub

An Azure-based customer enquiry management system with AI-powered classification, a conversational staff assistant, and automated alerting.

## Architecture

```
                        ┌─────────────────────────────────────────────────┐
                        │                  Azure (australiaeast)           │
                        │                                                  │
  Email / HTTP ─────────►  Logic App      ┌──────────────────────┐        │
                        │  (ingestion)    │   Azure API Mgmt     │        │
                        │      │          │   (rate-limit, CORS) │        │
                        │      ▼          └──────────┬───────────┘        │
                        │  Service Bus /             │                    │
                        │  Storage Queue  ◄──────────┘                    │
                        │      │         POST /submit                     │
                        │      ▼                                           │
                        │  Azure Functions (Python 3.11)                  │
                        │  ┌─────────────────────────────────┐            │
                        │  │  process_enquiry  (SB trigger)  │            │
                        │  │    └─► Azure OpenAI (GPT-4o)    │            │
                        │  │    └─► Cosmos DB (upsert)       │            │
                        │  │    └─► Event Grid (if Critical) │            │
                        │  │                                 │            │
                        │  │  submit_enquiry  (HTTP POST)    │            │
                        │  │  chat_endpoint   (HTTP POST)    │            │
                        │  └─────────────────────────────────┘            │
                        │      │              │                            │
                        │  Event Grid     Cosmos DB                       │
                        │      │          (Serverless)                    │
                        │      ▼                                           │
                        │  Logic App                                       │
                        │  (critical alert email)                         │
                        │                                                  │
                        │  Azure Static Web Apps (Entra ID auth)          │
                        │    Staff chatbot (index.html)                   │
                        │    /api/* proxied to Function App               │
                        └─────────────────────────────────────────────────┘
```

## Prerequisites

- Azure subscription with **Contributor** and **User Access Administrator** roles
- Azure OpenAI access enabled
- Azure CLI installed and authenticated (`az login`)
- Terraform >= 1.5
- GitHub CLI (`gh`)

## Setup

### 1. Terraform State Backend

```bash
az group create --name rg-terraform-state --location australiaeast

az storage account create \
  --resource-group rg-terraform-state \
  --name <GLOBALLY_UNIQUE_NAME> \
  --sku Standard_LRS \
  --location australiaeast

az storage container create \
  --name tfstate \
  --account-name <GLOBALLY_UNIQUE_NAME>
```

Update `terraform/main.tf` backend block with your storage account name.

### 2. Service Principal & OIDC

Follow the steps in `CLAUDE_CODE_INSTRUCTIONS.md` § "Service Principal with OIDC Federation" to create the app registration and federated credentials, then set GitHub secrets:

```bash
gh secret set AZURE_CLIENT_ID     --body "<APP_ID>"
gh secret set AZURE_TENANT_ID     --body "<TENANT_ID>"
gh secret set AZURE_SUBSCRIPTION_ID --body "<SUBSCRIPTION_ID>"
```

### 3. Terraform Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your values
```

### 4. Deploy Infrastructure

```bash
git push origin main   # triggers GitHub Actions infra pipeline
```

APIM provisioning takes 30–45 minutes.

### 5. Deploy Application

After Terraform completes:

1. Update the `app-name` placeholder in `.github/workflows/app.yml` with `terraform output function_app_name`
2. Store the SWA deployment token as a GitHub secret:

   ```bash
   gh secret set SWA_DEPLOYMENT_TOKEN --body "$(terraform output -raw swa_deployment_token)"
   ```

3. Grant admin consent for the SWA app registration in Entra ID (see [docs/deployment.md](docs/deployment.md) Step 5)
4. Push `src/` to trigger the app pipeline

See [docs/deployment.md](docs/deployment.md) for the full step-by-step guide.

## Messaging Paths

| Path | Variable value | Description |
|------|---------------|-------------|
| A — Standard | `standard` | Service Bus Standard SKU (default) |
| B — Premium | `premium` | Service Bus Premium with private endpoint |
| C — Storage Queue | `storagequeue` | Azure Storage Queue with private endpoint |

Set `messaging_path` in `terraform.tfvars` before first deploy. No code changes are required — `function_app.py` reads `MESSAGING_PATH` at import time and registers the correct trigger automatically.

## Cost Estimates (australiaeast, dev workloads)

| Resource | Approx. monthly cost |
|----------|---------------------|
| Azure Functions (Consumption) | ~$0 (free tier) |
| Cosmos DB Serverless | ~$1–5 |
| Service Bus Standard | ~$10 |
| Azure OpenAI (GPT-4o) | Pay-per-token |
| API Management (Developer) | ~$50 |
| Application Insights | ~$2–5 |
| Azure Static Web Apps (Free tier) | ~$0 |
| Storage (state + functions runtime) | ~$1 |

> Developer-tier APIM is not suitable for production. Upgrade to Basic or Standard for SLA.

## Cleanup

```bash
cd terraform
terraform destroy
```

Also delete the `rg-terraform-state` resource group manually if no longer needed.

## Documentation

- [docs/deployment.md](docs/deployment.md) — step-by-step first-deploy guide
- [docs/runbook.md](docs/runbook.md) — operational procedures: DLQ replay, cold-start mitigation, Cosmos throttle, APIM trace debugging, incident response
- [docs/kql-queries.md](docs/kql-queries.md) — three KQL queries for Log Analytics: latency percentiles, category/urgency distribution, and failed operations
- [docs/threat-model.md](docs/threat-model.md) — STRIDE threat model with 18 threats, residual risk ratings, and mitigations
