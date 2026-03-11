# End-to-End Testing Guide

## Project Goals

The following goals were defined for this project. Each is covered by a test section below.

| # | Goal |
|---|------|
| G1 | Accept customer enquiries via HTTP and route them to a messaging queue |
| G2 | Classify each enquiry with AI (urgency, category, summary, suggested action) |
| G3 | Store enriched enquiry records in Cosmos DB |
| G4 | Send a real-time alert when an enquiry is classified as Critical |
| G5 | Provide a natural-language staff assistant backed by live enquiry data |
| G6 | Secure the staff portal with organisational Entra ID login (no credentials in browser) |
| G7 | Rate-limit and govern external API access via API Management |
| G8 | Support three interchangeable messaging paths with no code changes |
| G9 | Provide observability via Application Insights and KQL queries |
| G10 | No credentials stored in source code; all Azure access via managed identity |
| G11 | All infrastructure defined as Terraform code with remote state |
| G12 | Deployments triggered by GitHub Actions with OIDC — no stored service principal secrets |

---

## Prerequisites

Before running these tests, confirm all deployment steps in `docs/deployment.md` are complete. You will need:

- The SWA URL: `terraform output web_endpoint`
- The APIM gateway URL: `terraform output apim_gateway_url`
- An APIM subscription key from the Azure Portal (APIM → Subscriptions)
- A tenant account that can sign in to Entra ID
- Access to the Azure Portal for verification steps

---

## Test 1 — Staff portal authentication (G6)

**Goal:** Unauthenticated access is blocked; Entra ID login is enforced.

1. Open the SWA URL in an **incognito / private** browser window (no cached session).
2. **Expected:** You are immediately redirected to `login.microsoftonline.com` — the staff portal page never loads.
3. Sign in with a tenant account.
4. **Expected:** You are redirected back to the staff portal and the chat UI is visible.
5. Open browser DevTools → Network tab. Confirm there is no `Authorization` header, no bearer token, and no API key in any request leaving the browser to `/api/*`.
6. **Expected:** Requests to `/api/chat` carry only a session cookie (`StaticWebAppsAuthCookie`) set to `HttpOnly`.

**Pass criteria:** Portal inaccessible without login; no credentials visible in DevTools.

---

## Test 2 — Submit enquiry (G1)

**Goal:** The `submit_enquiry` function accepts a POST and returns HTTP 202.

Run from a terminal (replace values with your APIM URL and key):

```bash
APIM_URL="https://apim-enquiryhub-dev.azure-api.net"
APIM_KEY="<your-subscription-key>"

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "${APIM_URL}/enquiry/submit" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -d '{
    "sender": "test.customer@example.com",
    "subject": "Test enquiry",
    "body": "This is an automated test enquiry submitted during end-to-end testing."
  }'
```

**Expected response:**
```json
{"message_id": "<uuid>", "status": "queued"}
```
**Expected HTTP status:** `202`

**Pass criteria:** 202 returned with a `message_id`.

---

## Test 3 — Validation rejects bad input (G1)

**Goal:** Missing required fields return HTTP 400.

```bash
# Missing 'body' field
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "${APIM_URL}/enquiry/submit" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -d '{"sender": "x@example.com", "subject": "Test"}'
```

**Expected:** `HTTP 400` with text `Missing required fields: body`

```bash
# Empty body
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "${APIM_URL}/enquiry/submit" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -d 'not-json'
```

**Expected:** `HTTP 400` with text `Request body must be valid JSON.`

**Pass criteria:** Both return 400 with descriptive messages; no stack trace or internal detail exposed.

---

## Test 4 — AI classification and Cosmos DB storage (G2, G3)

**Goal:** The `process_enquiry` function classifies the enquiry and stores the enriched record.

1. Submit the test enquiry from Test 2 (if not already submitted).
2. Wait ~30 seconds for the queue trigger to fire.
3. In the Azure Portal, navigate to **Cosmos DB → Data Explorer → EnquiryHub → Enquiries**.
4. Run the query: `SELECT * FROM c ORDER BY c.timestamp DESC OFFSET 0 LIMIT 1`

**Expected document structure:**
```json
{
  "id": "<uuid>",
  "dateKey": "2026-03-11",
  "timestamp": "2026-03-11T...",
  "sender": "test.customer@example.com",
  "subject": "Test enquiry",
  "body": "This is an automated test enquiry...",
  "urgency": "Low",
  "category": "General",
  "summary": "<one-sentence summary from OpenAI>",
  "suggestedAction": "<recommended action from OpenAI>",
  "status": "Open"
}
```

**Pass criteria:** Record exists with all fields populated; `urgency` and `category` are valid enum values.

---

## Test 5 — Critical alert via Event Grid (G4)

**Goal:** A Critical enquiry triggers an Event Grid event (and downstream Logic App email).

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "${APIM_URL}/enquiry/submit" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -d '{
    "sender": "angry.customer@example.com",
    "subject": "URGENT: Complete system failure affecting all users",
    "body": "Our entire platform is down. Hundreds of users are affected. We need immediate escalation and a response from senior management. This is a critical business incident."
  }'
```

1. Wait ~30 seconds for processing.
2. In the Azure Portal, navigate to **Event Grid Topic → Metrics** → set metric to `Published Events`.
3. **Expected:** A spike showing 1 published event.
4. In Application Insights → Traces, search for `Published Critical alert`.
5. If a Logic App is subscribed to the topic, verify the alert email was received.

**Pass criteria:** Event Grid metrics show a published event; App Insights trace confirms the alert was sent.

---

## Test 6 — Staff chatbot (G5)

**Goal:** The chat UI returns a relevant answer using real enquiry data.

1. Sign in to the staff portal (SWA URL).
2. In the chat input, type: `How many enquiries are open?`
3. **Expected:** A response based on actual Cosmos DB data, e.g. _"There are currently 3 open enquiries..."_
4. Ask a follow-up: `What are the most urgent ones?`
5. **Expected:** The assistant lists enquiries with `urgency: Critical` or `urgency: High` from the data.
6. Ask something outside the data: `What is the weather today?`
7. **Expected:** The assistant declines to answer or says the data does not contain that information — it does not hallucinate.

**Pass criteria:** Relevant answers are returned; answers are grounded in the Cosmos data; out-of-scope questions are declined.

---

## Test 7 — Chat endpoint validation (G5)

**Goal:** The `/api/chat` endpoint rejects bad input.

From the browser console (while signed in to the portal), run:

```javascript
// Missing question field
fetch("/api/chat", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({})
}).then(r => console.log(r.status))
// Expected: 400
```

**Pass criteria:** Returns 400 with `Missing 'question' field.`

---

## Test 8 — No credentials in browser source (G6, G10)

**Goal:** The deployed HTML contains no API keys, connection strings, or secrets.

1. In the browser (signed in to the portal), press F12 and open the Sources tab.
2. Find `index.html`.
3. **Verify none of the following appear in the source:**
   - `Ocp-Apim-Subscription-Key`
   - `apim-enquiryhub`
   - `YOUR_SUBSCRIPTION_KEY`
   - Any string matching `[A-Za-z0-9+/]{30,}` that looks like a key or token
4. **Expected:** The only API reference is `const CHAT_ENDPOINT = "/api/chat"` — a relative path with no credentials.

**Pass criteria:** No API keys, subscription keys, or credentials present in browser-visible source.

---

## Test 9 — APIM rate limiting (G7)

**Goal:** APIM rejects calls without a subscription key and enforces rate limits.

```bash
# Call without a subscription key
curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "${APIM_URL}/enquiry/submit" \
  -H "Content-Type: application/json" \
  -d '{"sender":"x","subject":"x","body":"x"}'
```

**Expected:** `HTTP 401` — APIM rejects the keyless request before it reaches the Function.

**Pass criteria:** 401 returned; Function App logs show no invocation for this request.

---

## Test 10 — Observability: KQL queries (G9)

**Goal:** All three KQL queries in `docs/kql-queries.md` return data.

1. In the Azure Portal, navigate to **Application Insights → Logs** (or the linked Log Analytics workspace).
2. Run each query from `docs/kql-queries.md` in turn.

| Query | Expected result |
|---|---|
| Function Execution Latency | Rows for `process_enquiry`, `submit_enquiry`, `chat_endpoint` with p50/p95/p99 values |
| Enquiry Volume by Category | Rows grouped by `category` and `urgency` for enquiries submitted in Tests 2 and 5 |
| Failed Operations | No rows (if all tests passed), or rows pinpointing the specific failure |

**Pass criteria:** All three queries execute without errors; latency and volume queries return data.

---

## Test 11 — Managed identity: no stored credentials (G10)

**Goal:** The Function App uses managed identity for all downstream calls — no connection strings stored.

1. In the Azure Portal, open the **Function App → Configuration → Application settings**.
2. **Verify the following are NOT present:**
   - Any key containing `password`, `secret`, `key`, or `connectionstring` for Cosmos DB or OpenAI
   - Any `AccountKey=` value for Storage (the functions runtime storage uses an access key, which is expected — verify only Cosmos and OpenAI are keyless)
3. Navigate to **Function App → Identity → System assigned** — confirm Status is **On** and a Principal ID is shown.
4. Navigate to **Azure RBAC → Role assignments** filtered to the resource group. Confirm the Function App identity holds only these roles:
   - `Cosmos DB Built-in Data Contributor`
   - `Azure Service Bus Data Receiver` (or Storage Queue Data Message Processor for path C)
   - `Azure Service Bus Data Sender`
   - `Cognitive Services OpenAI User`
   - `EventGrid Data Sender`
   - `Key Vault Secrets User`

**Pass criteria:** No Cosmos or OpenAI secrets in app settings; managed identity enabled; RBAC roles match the expected set.

---

## Test 12 — Unit tests (G2, G3)

**Goal:** All unit tests pass locally.

```bash
cd src/functions
pip install -r requirements.txt pytest pytest-mock
pytest tests/ -v
```

**Expected:** All tests pass with no failures.

**Pass criteria:** Exit code 0, no test failures.

---

## Test 13 — GitHub Actions deployment (G12)

**Goal:** A push to `main` triggers the workflow and both jobs succeed.

1. Make a trivial change (e.g. add a comment to `src/web/index.html`).
2. Commit and push to `main`.
3. In the GitHub repository, navigate to **Actions → Application**.
4. **Expected:** The workflow run starts automatically; both `Deploy Azure Functions` and `Deploy Static Web App` jobs complete with green checkmarks.
5. Confirm no credentials are stored as repository secrets other than:
   - `AZURE_CLIENT_ID` — app registration client ID (not a secret)
   - `AZURE_TENANT_ID` — tenant ID (not a secret)
   - `AZURE_SUBSCRIPTION_ID` — subscription ID (not a secret)
   - `SWA_DEPLOYMENT_TOKEN` — SWA deployment token (this is a secret, stored correctly)

**Pass criteria:** Both deploy jobs succeed; OIDC is used (no `AZURE_CLIENT_SECRET` in secrets).

---

## Test 14 — Terraform state integrity (G11)

**Goal:** Infrastructure is fully described in code and state is consistent.

```bash
cd terraform
terraform plan
```

**Expected output:**
```
No changes. Your infrastructure matches the configuration.
```

**Pass criteria:** `terraform plan` reports no drift. If changes are shown, investigate before applying.

---

## Summary checklist

| Test | Goal(s) | Pass? |
|---|---|---|
| T1 — Portal authentication | G6 | |
| T2 — Submit enquiry | G1 | |
| T3 — Input validation | G1 | |
| T4 — AI classification + Cosmos storage | G2, G3 | |
| T5 — Critical alert | G4 | |
| T6 — Staff chatbot | G5 | |
| T7 — Chat validation | G5 | |
| T8 — No credentials in source | G6, G10 | |
| T9 — APIM rate limiting | G7 | |
| T10 — KQL queries | G9 | |
| T11 — Managed identity | G10 | |
| T12 — Unit tests | G2, G3 | |
| T13 — GitHub Actions | G12 | |
| T14 — Terraform plan | G11 | |
