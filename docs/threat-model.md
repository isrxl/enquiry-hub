# Threat Model — Enquiry Hub

STRIDE analysis of the Enquiry Hub system. Each threat is rated **High / Medium / Low**
based on likelihood × impact given the current controls.

---

## System Boundary

```text
External senders → Email / Queue → Azure Functions → Cosmos DB
                                        ↓
                               Azure OpenAI (classify + chat)
                                        ↓
                               Event Grid (Critical alerts)
                                        ↓
                               Logic App → Email notifications
Staff browser → Static Web (Azure Blob) → APIM → Azure Functions
```

Key trust boundaries:

- **External / internal** — anything originating outside the Azure subscription
- **Data plane / control plane** — Azure RBAC separates data access from infrastructure changes
- **Function / data stores** — managed identity; no connection strings in app settings

---

## S — Spoofing

### Threat 1: Forged enquiry sender field

- _Attack_: Attacker submits a queue message with a spoofed `sender` value.
- _Controls_: Queue is internal; external entry is the email-to-queue adapter, not a public endpoint.
- _Residual risk_: **Low**
- _Recommendation_: Validate sender against an allow-list in `_classify_enquiry` if sender identity is security-relevant.

### Threat 2: Keyless APIM calls

- _Attack_: Caller omits or guesses the APIM subscription key.
- _Controls_: `Ocp-Apim-Subscription-Key` required on every request; APIM rejects keyless calls with HTTP 401.
- _Residual risk_: **Low**
- _Recommendation_: Rotate keys periodically; consider Azure AD–based APIM auth for stronger identity assurance.

### Threat 3: Stolen managed identity token

- _Attack_: Token exfiltrated from a compromised Function instance and used to call downstream services.
- _Controls_: Tokens are short-lived (≤1 h) and scoped to specific resources via RBAC.
- _Residual risk_: **Low**
- _Recommendation_: Enable Defender for App Service to detect anomalous token usage.

---

## T — Tampering

### Threat 4: Cosmos DB document altered after write

- _Attack_: Insider or compromised identity modifies an enquiry record.
- _Controls_: RBAC role is "Built-in Data Contributor" (read + write).
- _Residual risk_: **Medium** — no write-once guarantee
- _Recommendation_: Add a Cosmos DB Change Feed audit log; use "Built-in Data Reader" for the chat function.

### Threat 5: Queue message tampered in transit

- _Attack_: Message body modified between producer and consumer.
- _Controls_: Service Bus / Storage Queue encrypts data at rest and in transit (TLS 1.2+).
- _Residual risk_: **Low**
- _Recommendation_: Enable Service Bus Premium with private endpoint (`messaging_path = "premium"`).

### Threat 6: Terraform state tampered

- _Attack_: Attacker modifies state to provision malicious infrastructure on the next apply.
- _Controls_: State stored in Azure Blob; access requires Storage Blob Data Contributor.
- _Residual risk_: **Low**
- _Recommendation_: Enable soft-delete and versioning on the Terraform state container.

---

## R — Repudiation

### Threat 7: Staff denies sending a chat query

- _Attack_: Staff member disputes having queried sensitive data.
- _Controls_: APIM logs all requests (method, path, timestamp, subscription key ID) to Application Insights.
- _Residual risk_: **Medium** — key identifies the subscription, not the individual user
- _Recommendation_: Replace subscription-key auth with Azure AD tokens to tie each request to a named identity.

### Threat 8: Enquiry processing denies writing a record

- _Attack_: Function disputes having stored a specific enquiry.
- _Controls_: App Insights traces every `_process_enquiry_impl` call with enquiry ID and outcome.
- _Residual risk_: **Low**
- _Recommendation_: Retain Application Insights data for ≥90 days via workspace retention settings.

---

## I — Information Disclosure

### Threat 9: Cosmos DB data exposed publicly

- _Attack_: Public endpoint accessed directly, bypassing APIM.
- _Controls_: Private endpoint on `privatelink.documents.azure.com`; public network access disabled.
- _Residual risk_: **Low**
- _Recommendation_: Periodically verify with `az cosmosdb show --query publicNetworkAccess`.

### Threat 10: PII in OpenAI prompt logs

- _Attack_: Enquiry PII captured in Azure OpenAI content logs.
- _Controls_: Azure OpenAI content logging is off by default for the S0 tier.
- _Residual risk_: **Low**
- _Recommendation_: Confirm content logging policy in Azure OpenAI Studio → Deployment settings.

### Threat 11: Subscription key visible in browser source

- _Attack_: Any authenticated staff member extracts the APIM key from `index.html` source.
- _Controls_: None — the key is embedded in client-side JavaScript.
- _Residual risk_: **High**
- _Recommendation_: Move APIM auth to Azure AD tokens (also resolves Threat 7); or proxy via a server-side endpoint that injects the key.

### Threat 12: Internal error details in HTTP responses

- _Attack_: Error messages reveal Cosmos DB schema, connection details, or stack traces.
- _Controls_: Both HTTP functions catch exceptions and return only safe strings.
- _Residual risk_: **Low**
- _Recommendation_: Add an APIM error policy to strip any residual detail headers.

---

## D — Denial of Service

### Threat 13: APIM endpoint flooding

- _Attack_: Attacker or runaway client floods `submit_enquiry` or `chat_endpoint`.
- _Controls_: APIM rate-limiting policy per subscription.
- _Residual risk_: **Medium** — Developer SKU has no SLA; a flood could exhaust the Consumption plan
- _Recommendation_: Add rate-limit-by-key APIM policy; upgrade to Basic/Standard before production.

### Threat 14: OpenAI quota exhaustion

- _Attack_: Runaway chat requests deplete the token quota.
- _Controls_: Deployment capacity capped at 10 TPM; excess requests return HTTP 429.
- _Residual risk_: **Low**
- _Recommendation_: Alert on sustained 429s (see `monitoring/alerts.tf`).

### Threat 15: Cosmos DB throttling

- _Attack_: Write burst triggers Cosmos DB 429 responses.
- _Controls_: Serverless Cosmos auto-scales; alert configured in `alerts.tf`.
- _Residual risk_: **Low**
- _Recommendation_: Add retry logic with exponential back-off in `function_app.py`.

---

## E — Elevation of Privilege

### Threat 16: Compromised Function escalates to subscription owner

- _Attack_: Attacker uses the managed identity to take over the subscription.
- _Controls_: Identity holds only the five RBAC roles in `rbac.tf`; no Owner/Contributor assignments.
- _Residual risk_: **Low**
- _Recommendation_: Review role assignments after every `terraform apply`.

### Threat 17: Prompt injection via enquiry body

- _Attack_: Attacker embeds instructions in an enquiry to manipulate the OpenAI model.
- _Controls_: System prompt is static; model instructed to answer only from Cosmos context.
- _Residual risk_: **Medium** — LLM prompt injection is an active research area
- _Recommendation_: Sanitise user input before embedding in the prompt; consider Azure AI Content Safety.

### Threat 18: APIM HTTP header smuggling

- _Attack_: Malformed headers bypass APIM inbound policies.
- _Controls_: APIM normalises headers by default.
- _Residual risk_: **Low**
- _Recommendation_: Upgrade to Isolated tier for production to remove shared-gateway exposure.

---

## Risk Summary

| Rating | Count | Key items                                            |
|--------|-------|------------------------------------------------------|
| High   | 0     | Threat 11 resolved (SWA + Entra ID auth enforced)    |
| Medium | 3     | Cosmos write (T4), DoS (T13), prompt injection (T17) |
| Low    | 15    | Remaining threats — sufficient for dev/staging       |

Threat 7 (repudiation) is now **Low**: Entra ID via SWA ties every chat request
to a named user identity. Threat 11 (info disclosure) is **Resolved**: the APIM
subscription key no longer appears in browser-visible code.

---

## Accepted Gaps

### Defender for Cloud — workload protection plans not enabled

- _Context_: The deployment uses the **Foundational CSPM** plan (free tier), which
  provides Secure Score recommendations and asset inventory but no Defender threat
  protection alerts (e.g. Defender for App Service, Defender for Key Vault).
- _Compensating controls_: Microsoft Sentinel is deployed with three custom analytics
  rules covering the highest-priority threats (APIM auth failures, DoS spike, RBAC
  changes). Azure Monitor metric alerts cover Function failures, Cosmos throttling,
  Service Bus DLQ depth, and APIM error rates. All alerts notify `easy@alphaio.com.au`.
- _Residual risk_: **Medium** — automated threat intelligence and anomaly detection
  are absent. A low-and-slow attack may not trigger the custom threshold-based rules.
- _Recommendation_: Enable **Defender for App Service** and **Defender for Key Vault**
  before handling production customer data. Monthly cost is approximately $15–20 AUD
  for this workload size. Re-evaluate Secure Score quarterly.
