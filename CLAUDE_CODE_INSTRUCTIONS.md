# Customer Enquiry Hub — Claude Code Build Instructions

## Overview

Build a complete Azure-based Customer Enquiry Hub with Terraform IaC, GitHub Actions CI/CD, Azure Functions (Python), Azure OpenAI, and a static web chatbot. The solution receives customer enquiries, classifies them with AI, stores enriched records, and provides a conversational interface for staff.

**Tech stack:** Terraform, GitHub Actions (OIDC), Python 3.11, Azure Functions v4, Azure Service Bus, Azure Cosmos DB (Serverless), Azure OpenAI (GPT-4o), Azure API Management, Azure Static Web Apps (Entra ID auth), Azure Event Grid, Logic Apps, Application Insights, Azure Monitor, Microsoft Sentinel.

**Messaging path:** The solution supports three messaging paths controlled by a Terraform variable (`messaging_path`). Default to `standard` (Service Bus Standard). The other options are `premium` (Service Bus Premium with private endpoint) and `storagequeue` (Azure Storage Queue with private endpoint).

---

## ⚠️ BEFORE YOU START — Human Actions Required

The following must be completed by the human before Claude Code begins any work. These involve Azure Portal/CLI operations and GitHub configuration that cannot be done from a code editor.

### 1. Azure Prerequisites
- [ ] Active Azure subscription with **Contributor** and **User Access Administrator** roles
- [ ] Azure OpenAI access enabled (request at https://aka.ms/oai/access if needed)
- [ ] Azure CLI installed and authenticated (`az login`)

### 2. Terraform State Backend (run manually)
```bash
az group create --name rg-terraform-state --location australiaeast

# Note: pick a globally unique name and provide it to Claude Code
az storage account create \
  --resource-group rg-terraform-state \
  --name <TFSTATE_STORAGE_NAME> \
  --sku Standard_LRS \
  --location australiaeast

az storage container create \
  --name tfstate \
  --account-name <TFSTATE_STORAGE_NAME>
```

### 3. GitHub Repository
```bash
gh repo create enquiry-hub --public --clone
cd enquiry-hub
```

### 4. Service Principal with OIDC Federation
```bash
$SUB_ID=$(az account show --query id -o tsv)
$APP_ID=$(az ad app create --display-name github-enquiryhub --query appId -o tsv)
az ad sp create --id $APP_ID

az role assignment create --assignee $APP_ID --role Contributor --scope /subscriptions/$SUB_ID
az role assignment create --assignee $APP_ID --role "User Access Administrator" --scope /subscriptions/$SUB_ID

# Replace <GITHUB_USERNAME> with your GitHub username
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:isrxl/enquiry-hub:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-pr",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<GITHUB_USERNAME>/enquiry-hub:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

### 5. GitHub Secrets
```bash
gh secret set AZURE_CLIENT_ID --body "<APP_ID from above>"
gh secret set AZURE_TENANT_ID --body "$(az account show --query tenantId -o tsv)"
gh secret set AZURE_SUBSCRIPTION_ID --body "$(az account show --query id -o tsv)"
```

### 6. Information to Provide to Claude Code
Once the above is complete, provide these values:
- `TFSTATE_STORAGE_NAME`: enquiryhubx7qp9mk
- `AZURE_REGION`: australiaeast
- `MESSAGING_PATH`: standard
- `GITHUB_USERNAME`: isrxl

---

## Phase 1: Repository Structure & CI/CD Pipelines

**Goal:** Create the full directory structure, .gitignore, and both GitHub Actions workflow files.

### Tasks

1. **Create directory structure:**
   ```
   enquiry-hub/
   ├── terraform/
   │   ├── main.tf
   │   ├── variables.tf
   │   ├── outputs.tf
   │   ├── terraform.tfvars.example   # Template (not gitignored)
   │   └── modules/
   │       ├── networking/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   └── outputs.tf
   │       ├── messaging/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   └── outputs.tf
   │       ├── data/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   └── outputs.tf
   │       ├── ai/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   └── outputs.tf
   │       ├── security/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   └── outputs.tf
   │       ├── monitoring/
   │       │   ├── main.tf
   │       │   ├── variables.tf
   │       │   ├── outputs.tf
   │       │   └── alerts.tf
   │       └── compute/
   │           ├── main.tf
   │           ├── rbac.tf
   │           ├── variables.tf
   │           └── outputs.tf
   ├── src/
   │   ├── functions/
   │   │   ├── function_app.py
   │   │   ├── requirements.txt
   │   │   └── host.json
   │   └── web/
   │       ├── index.html
   │       └── staticwebapp.config.json
   ├── docs/
   │   ├── kql-queries.md
   │   ├── threat-model.md
   │   ├── deployment.md
   │   └── runbook.md
   ├── .github/
   │   └── workflows/
   │       ├── infra.yml
   │       └── app.yml
   ├── .gitignore
   └── README.md
   ```

2. **Create .gitignore:**
   - Terraform: `*.tfstate`, `*.tfstate.backup`, `.terraform/`, `*.tfvars` (but NOT `*.tfvars.example`)
   - Python: `__pycache__/`, `.venv/`, `*.pyc`
   - Azure Functions: `local.settings.json`
   - General: `.env`, `.DS_Store`

3. **Create .github/workflows/infra.yml:**
   - Trigger: push to `main` on `terraform/**` paths + PR on `terraform/**` paths
   - Permissions: `id-token: write`, `contents: read`
   - Environment variables: `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `ARM_USE_OIDC: true`
   - Steps: checkout, setup-terraform, `terraform init`, `terraform validate`, `terraform plan` (on PR), `terraform apply -auto-approve` (on push to main)
   - Working directory: `terraform`

4. **Create .github/workflows/app.yml:**
   - Trigger: push to `main` on `src/**` paths
   - Permissions: `id-token: write`, `contents: read`
   - Job 1 `deploy-functions`: checkout, setup-python 3.11, azure/login (OIDC), pip install requirements, Azure/functions-action deploy
   - Job 2 `deploy-web`: checkout, deploy via `azure/static-web-apps-deploy@v1` using `SWA_DEPLOYMENT_TOKEN` secret
   - NOTE: Function app name will need to be updated after Terraform outputs are known. Use placeholder comment `# TODO: Replace with Terraform output (function_app_name)`

5. **Create terraform.tfvars.example** (committed, not gitignored) showing the variable structure with placeholder values.

6. **Create README.md** with project overview, architecture description, prerequisites, and setup instructions.

### 🔍 REVIEW POINT 1
**Pause here.** Human reviews the repo structure, pipeline files, and .gitignore before proceeding. Human creates `terraform.tfvars` from the example template with their actual values.

---

## Phase 2: Terraform Infrastructure Modules

**Goal:** Write all Terraform modules to provision the complete Azure environment.

### Tasks

7. **terraform/main.tf (root module):**
   - Terraform block: required version >= 1.5, azurerm provider ~> 3.100
   - Backend: azurerm with the state storage account provided by human
   - Provider: `azurerm { features {} }`
   - Resource: `azurerm_resource_group.main`
   - Module calls for: networking, messaging, data, ai, security, monitoring, compute
   - Wire module outputs to module inputs (e.g., networking outputs → messaging/data/ai inputs)

8. **terraform/variables.tf:**
   - `project_name` (string, default "enquiryhub")
   - `location` (string, default "australiaeast")
   - `environment` (string, default "dev")
   - `messaging_path` (string, default "standard", validation: must be standard/premium/storagequeue)
   - `openai_model` (string, default "gpt-4o")
   - `apim_publisher_email` (string, default "admin@example.com") — set in terraform.tfvars
   - `alert_email` (string, default "admin@example.com") — set in terraform.tfvars; used by Monitor action group

9. **terraform/modules/networking/:**
   - VNET: 10.0.0.0/16
   - Subnet snet-apim: 10.0.1.0/24
   - Subnet snet-functions: 10.0.2.0/24, delegated to Microsoft.Web/serverFarms
   - Subnet snet-private-endpoints: 10.0.3.0/24, private_endpoint_network_policies = Disabled
   - NSG on PE subnet: allow inbound from functions subnet (10.0.2.0/24) and APIM subnet (10.0.1.0/24 port 443); deny all other inbound. Note: NSG rules are not enforced on PE NICs directly (network_policies disabled) but provide defence-in-depth.
   - Outputs: vnet_id, functions_subnet_id, pe_subnet_id, apim_subnet_id

10. **terraform/modules/messaging/:**
    - Use locals to derive booleans: `is_sb_standard`, `is_sb_premium`, `is_storage_queue`, `is_service_bus`
    - Paths A&B: `azurerm_servicebus_namespace` (count on is_service_bus, SKU conditional on premium), `azurerm_servicebus_queue` with dead_lettering enabled
    - Path B only: private endpoint + private DNS zone + VNET link for Service Bus
    - Path C: `azurerm_storage_account` + `azurerm_storage_queue` + private endpoint + private DNS zone + VNET link
    - Outputs: sb_fqdn (nullable), sb_id (nullable), queue_conn_string (nullable, sensitive), messaging_path

11. **terraform/modules/data/:**
    - `azurerm_cosmosdb_account` (Serverless, GlobalDocumentDB, Session consistency)
    - `azurerm_cosmosdb_sql_database` "EnquiryHub"
    - `azurerm_cosmosdb_sql_container` "Enquiries" with partition key `/dateKey`
    - Private endpoint + private DNS zone + VNET link
    - Outputs: cosmosdb_endpoint, cosmosdb_id, cosmosdb_account_name

12. **terraform/modules/ai/:**
    - `azurerm_cognitive_account` (kind=OpenAI, sku=S0)
    - `azurerm_cognitive_deployment` for the specified model (GlobalStandard, capacity 10)
    - Private endpoint + private DNS zone + VNET link
    - Outputs: openai_endpoint, openai_id

13. **terraform/modules/security/:**
    - `azurerm_key_vault` with RBAC authorization enabled
    - Outputs: keyvault_id

14. **terraform/modules/monitoring/:**
    - `azurerm_log_analytics_workspace` (PerGB2018, 90-day retention)
    - `azurerm_application_insights` (linked to workspace)
    - Microsoft Sentinel: `azurerm_sentinel_log_analytics_workspace_onboarding` + 3 scheduled analytics rules:
      - APIM auth failure spike (>20 401s from single IP in 1h, severity=Medium)
      - APIM request volume spike (>100 requests in any 1-min window, severity=High)
      - Unexpected RBAC change (any successful roleAssignments/write or /delete, severity=High)
    - **alerts.tf:** `azurerm_monitor_action_group` with `email_receiver` using `var.alert_email`; Service Bus DLQ alert (DeadLetteredMessages Maximum > 0, severity=1, auto_mitigate=false); APIM error rate alert (Requests total > 10 with GatewayResponseCodeCategory dimension filtering 4xx/5xx, severity=2)
    - Variables: `project_name`, `environment`, `location`, `resource_group_name`, `alert_email`
    - Outputs: ai_connection_string (sensitive), ai_instrumentation_key (sensitive), log_analytics_workspace_id

15. **terraform/modules/compute/:**
    - **main.tf:**
      - `azurerm_storage_account` for Functions runtime
      - `azurerm_service_plan` (Linux, Y1 Consumption)
      - `azurerm_linux_function_app` with:
        - System-assigned managed identity
        - VNET integration (functions subnet)
        - vnet_route_all_enabled = true
        - Python 3.11 stack
        - App settings: COSMOS_ENDPOINT, COSMOS_DATABASE, COSMOS_CONTAINER, OPENAI_ENDPOINT, OPENAI_DEPLOYMENT, APPLICATIONINSIGHTS_CONNECTION_STRING, SERVICE_BUS_FQDN, SERVICE_BUS_QUEUE, AzureWebJobsQueueStorage
        - `ip_restriction_default_action = "Deny"` with two allow rules: APIM public IP (`/32`) at priority 100, `AzureStaticWebApps` service tag at priority 110
      - `azurerm_api_management` (Developer_1 SKU)
      - `azurerm_monitor_diagnostic_setting` sending APIM GatewayLogs + AllMetrics to Log Analytics (feeds Sentinel analytics rules)
      - `azurerm_eventgrid_topic` for critical enquiries
      - `azurerm_key_vault_secret` for Event Grid key
      - Azure Static Web App stack (replaces static storage hosting):
        - `azuread_application` + `azuread_application_password` for SWA Entra ID auth
        - `azuread_application_redirect_uris` as separate resource (avoids circular dependency)
        - `azurerm_static_web_app` with `azurerm_static_web_app_function_app_registration` linking to Function App
        - SWA provides built-in Entra ID auth (server-side OAuth, HttpOnly cookie) — `/api/*` proxied to Function App via linked backend
    - **rbac.tf:**
      - Service Bus Data Receiver + Sender (count on sb_id != null)
      - Cosmos DB Built-in Data Contributor (via `azurerm_cosmosdb_sql_role_assignment`)
      - Cognitive Services OpenAI User
      - Key Vault Secrets User
      - EventGrid Data Sender on the Event Grid topic (for managed identity to publish critical enquiry events)
    - Providers: `azurerm ~> 3.100` and `azuread ~> 2.50` (required for Entra ID app registration)
    - Outputs: function_app_name, function_app_id, apim_gateway_url, web_endpoint, swa_deployment_token (sensitive)

16. **terraform/outputs.tf (root):**
    - Expose key values: function_app_name, apim_gateway_url, web_endpoint, resource_group_name, swa_deployment_token (sensitive)

### 🔍 REVIEW POINT 2
**Pause here.** Human reviews all Terraform files, creates `terraform.tfvars` with their actual values, and runs:
```bash
cd terraform
terraform init
terraform validate
terraform plan
```
Human confirms the plan looks correct before proceeding.

### ⚠️ HUMAN ACTION: First Deploy
After review, human runs:
```bash
git add -A
git commit -m "Add all Terraform modules"
git push origin main
```
Human monitors GitHub Actions and confirms `terraform apply` succeeds. APIM will take 30-45 minutes.

### ⚠️ HUMAN ACTION: Update App Pipeline
After Terraform completes, human updates `.github/workflows/app.yml` with the function app name from `terraform output function_app_name`, then commits and pushes. Also run:

```bash
gh secret set SWA_DEPLOYMENT_TOKEN --body "$(terraform output -raw swa_deployment_token)"
```

---

## Phase 3: Application Code — Functions

**Goal:** Write the Azure Functions application code (processor, submit, chat).

### Tasks

17. **src/functions/host.json:**
    - Standard Azure Functions v4 host config
    - Extension bundles for Service Bus and Storage Queue triggers

18. **src/functions/requirements.txt:**
    - azure-functions, azure-cosmos, azure-identity, openai, azure-servicebus, azure-storage-queue, requests

19. **src/functions/function_app.py:**
    Write THREE functions in a single file:

    **a) `process_enquiry` — Service Bus/Queue trigger:**
    - Paths A&B: `@app.service_bus_queue_trigger` on `enquiry-queue`, connection `SERVICE_BUS_FQDN`
    - Path C: `@app.queue_trigger` on `enquiry-queue`, connection `AzureWebJobsQueueStorage`
    - Use `if/else` on `MESSAGING_PATH` env var at module import time to register only the active trigger decorator — do NOT comment out inactive code
    - Parse JSON body, call Azure OpenAI (GPT-4o) for classification using structured JSON output
    - Classification prompt should return: urgency (Critical/High/Medium/Low), category (Complaint/Quote Request/Support/General), summary, suggested_action
    - Build enriched document with: id, dateKey (YYYY-MM-DD), timestamp, sender, subject, body, urgency, category, summary, suggestedAction, status="Open"
    - Upsert to Cosmos DB
    - If urgency == "Critical": publish Event Grid event with sender, summary, category
    - Use managed identity for all service authentication (DefaultAzureCredential)
    - Use `azure_ad_token_provider` pattern for OpenAI client

    **b) `submit_enquiry` — HTTP trigger (POST /submit):**
    - Validate JSON body has sender, subject, body fields
    - Paths A&B: Send to Service Bus queue using ServiceBusClient with managed identity
    - Path C: Send to Storage Queue (base64 encoded) using QueueClient with connection string
    - Implement as two named functions (`_send_to_service_bus`, `_send_to_storage_queue`) with a `_send_enquiry` pointer set at module load based on `MESSAGING_PATH` — do NOT comment out inactive code
    - Return 202 with message ID

    **c) `chat_endpoint` — HTTP trigger (POST /chat):**
    - Accept JSON with `question` field
    - Query top 50 recent enquiries from Cosmos DB (ORDER BY timestamp DESC, cross-partition)
    - Pass enquiry data as context + user question to Azure OpenAI
    - System prompt: helpful business assistant, answer based on provided data, be concise
    - Temperature: 0.3
    - Return JSON with `answer` field

### 🔍 REVIEW POINT 3
**Pause here.** Human reviews function code, confirms the `MESSAGING_PATH` app setting matches the provisioned infrastructure, and approves.

### ⚠️ HUMAN ACTION: Deploy Functions
```bash
git add src/functions/
git commit -m "Add Azure Functions code"
git push origin main
```
Human monitors the Application pipeline and verifies functions appear in the Portal.

---

## Phase 4: Application Code — Frontend & Documentation

**Goal:** Build the chatbot frontend and project documentation.

### Tasks

20. **src/web/index.html:**
    - Clean, responsive single-page chat interface
    - Header: "Enquiry Hub Assistant"
    - Messages area with user (orange) and bot (light blue) message bubbles
    - Input field + Send button
    - JavaScript: POST to relative URL `/api/chat` — no APIM URL or subscription key in the browser. SWA linked backend proxies this to the Function App.
    - Handle loading state and errors gracefully

20b. **src/web/staticwebapp.config.json:**
    - Route all requests to `index.html` (SPA fallback)
    - Require authentication on all routes (`isAuthenticated` role)
    - Configure Entra ID as the identity provider

21. **docs/kql-queries.md:**
    - Enquiry processing latency (avg, p95, count, failure count by hour)
    - Category/urgency distribution
    - Failed operations in last 24 hours
    - Each query with title, description, and KQL code block

22. **docs/threat-model.md:**
    - STRIDE threat model structured as sections (one per STRIDE category) with per-threat narrative analysis
    - Risk summary table (High/Medium/Low counts)
    - Accepted Gaps section documenting Defender for Cloud limitation (Foundational CSPM only) with compensating controls (Sentinel custom KQL rules + Monitor alerts) and residual risk rating
    - Cover: Spoofing (APIM auth + Entra ID via SWA), Tampering (TLS + message integrity), Repudiation (App Insights logging), Information Disclosure (private endpoints + RBAC), DoS (rate limiting + queue buffering), Elevation of Privilege (managed identity + least-privilege + RBAC change alert)

23. **docs/deployment.md:**
    - Step-by-step first-deploy guide covering: set terraform.tfvars (apim_publisher_email, alert_email), terraform init, terraform apply, update app.yml with function app name, store SWA deployment token as GitHub secret, grant admin consent in Entra ID, deploy via git push, verify end-to-end

24. **docs/runbook.md:**
    - Operational procedures for: DLQ investigation and replay, Function App cold-start mitigation, Cosmos DB RU throttle and partition hotspot, APIM policy debugging with trace mode, incident response workflow (P1/P2/P3 severity classification + 7-step process)

23. **README.md (update):**
    - Architecture diagram (ASCII or mermaid)
    - Prerequisites section
    - Setup instructions referencing terraform.tfvars.example
    - Three messaging paths explained
    - Cost estimates
    - Cleanup instructions (terraform destroy)

### 🔍 REVIEW POINT 4
**Pause here.** Human reviews frontend, docs, and README.

### ⚠️ HUMAN ACTION: Final Deploy & Configuration
1. Push all remaining code:
   ```bash
   git add -A
   git commit -m "Add frontend, docs, and README"
   git push origin main
   ```
2. In Azure Portal, configure APIM:
   - Import Function App as API backend
   - Add inbound policies: rate-limit (10/min), CORS, content validation
   - Note the subscription key (used only by external `/submit` callers, not by the SWA frontend)
3. Grant admin consent in Entra ID for the SWA app registration (see deployment.md Step 5)
4. Create Logic Apps manually in Portal:
   - **logic-email-ingestion:** Email trigger → Compose JSON → HTTP POST to APIM /submit
   - **logic-critical-alerts:** Event Grid trigger (egt-critical topic) → Send email notification
5. Test end-to-end:
   - Submit enquiry via curl/Postman to APIM /submit endpoint
   - Verify Cosmos DB record with classification
   - Test chatbot via the static website
   - Submit a critical enquiry and verify email alert

---

## Summary of Review Points

| Point | After Phase | Human Reviews | Human Actions |
| --- | --- | --- | --- |
| 1 | Repo & CI/CD | Directory structure, pipelines, .gitignore | Create terraform.tfvars |
| 2 | Terraform | All .tf files, terraform plan output | First git push, monitor pipeline, update app.yml, store SWA_DEPLOYMENT_TOKEN secret |
| 3 | Functions | Python code, MESSAGING_PATH app setting correct | Push function code, monitor deploy |
| 4 | Frontend & Docs | HTML, staticwebapp.config.json, KQL queries, threat model, deployment.md, runbook.md, README | Push code, grant Entra ID admin consent, configure APIM & Logic Apps, test e2e |
