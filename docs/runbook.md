# Operational Runbook — Enquiry Hub

Procedures for investigating and resolving common operational issues. Each section maps to a specific alert or failure mode.

---

## 1. Dead-Letter Queue Investigation and Replay

**Triggered by:** Alert `alert-sb-dlq-dev` fires (Service Bus DLQ depth > 0)

**What it means:** One or more enquiry messages failed processing beyond the Service Bus retry limit (default: 10 attempts) and have been moved to the dead-letter queue. No data is lost — DLQ messages are retained until explicitly deleted.

**Investigation steps:**

1. Open **Service Bus → Queues → enquiry-queue → Dead-letter** in the Azure Portal.
2. Click **Peek** to read the message body without consuming it.
3. Check the `DeadLetterReason` and `DeadLetterErrorDescription` properties — common values:
   - `MaxDeliveryCountExceeded` — processing threw an exception on every retry
   - `TTLExpiredException` — message sat in the queue too long before being picked up
4. Open **Application Insights → Failures** and search for the enquiry sender or timestamp to find the corresponding exception. The `_process_enquiry_impl` function logs enquiry IDs on every invocation.
5. Identify the root cause (e.g. Cosmos DB outage, OpenAI timeout, malformed message body).

**Resolution:**

- If the root cause is fixed: re-send the message by copying its body and posting it to the `/submit` APIM endpoint, or use Service Bus Explorer to manually resubmit.
- If the message body is malformed: delete it from the DLQ after documenting the content.
- To bulk-replay: use the Azure Service Bus Explorer tool (`npm install -g @azure/service-bus-explorer`) or write a one-off script using the `azure-servicebus` SDK.

**Prevent recurrence:** If the failure is systemic (e.g. OpenAI outages causing timeouts), consider adding a retry/back-off policy in `_process_enquiry_impl` or increasing the Service Bus message lock duration.

---

## 2. Function App Scaling and Cold-Start Mitigation

**Triggered by:** p95 latency spike in KQL Query 1, or user-reported chat delays after periods of inactivity.

**What it means:** The Consumption plan (Y1) scales to zero when idle. The first request after idle spins up a new instance (cold start), which for Python + multiple SDK imports typically adds 3–8 seconds of latency.

**Investigation steps:**

1. In **Application Insights → Performance**, check the `process_enquiry` and `chat_endpoint` duration percentiles.
2. Look for a pattern: are slow requests the first ones after a gap? This confirms cold starts rather than a code regression.
3. Check the `FunctionExecutionCount` metric in Azure Monitor for the Function App — zero counts confirm the instance scaled to zero.

**Mitigation options (in order of cost):**

| Option | Cost impact | Steps |
|---|---|---|
| Accept cold starts (current) | None | No action — suitable for low-frequency dev/test usage |
| Always-on via minimum instance count | Adds ~$5/month | In `azurerm_linux_function_app`, add `minimum_instance_count = 1` to `site_config` |
| Upgrade to Elastic Premium (EP1) | ~$150/month | Change `sku_name = "EP1"` in `azurerm_service_plan.main` and redeploy |

For production workloads with an SLA, upgrade to EP1 and set `minimum_instance_count = 1`.

---

## 3. Cosmos DB RU Consumption and Partition Hotspot Detection

**Triggered by:** Alert `alert-cosmos-throttle-dev` fires (429 responses), or chat endpoint latency spikes.

**What it means:** The serverless Cosmos DB account is being rate-limited. Either a burst of writes/reads exceeded the per-partition RU limit, or a partition hotspot has formed.

**Investigation steps:**

1. In **Application Insights → Logs**, run:
   ```kql
   dependencies
   | where type == "Azure DocumentDB"
   | where success == false
   | summarize count() by bin(timestamp, 1m), name
   | order by timestamp desc
   ```
2. Look for which operation is failing: `upsert_item` (writes in `process_enquiry`) or `query_items` (reads in `chat_endpoint`).
3. In **Cosmos DB → Metrics**, check `Total Request Units` broken down by `StatusCode = 429` to identify the time window.
4. In **Cosmos DB → Insights**, check the `Normalized RU Consumption` per partition key — values near 100% indicate a hotspot.

**Common hotspot cause:** All enquiries submitted on the same day share the partition key `/dateKey = YYYY-MM-DD`. High write volume on the same date will concentrate RUs on one partition.

**Resolution:**

- Short-term: reduce write frequency by rate-limiting at APIM, or batch enquiries.
- Long-term: add a suffix to the partition key (e.g. `YYYY-MM-DD-HH`) to spread load, or switch to `id` as the partition key if cross-partition chat queries are acceptable.
- For the chat endpoint specifically: cache the Cosmos query result in-memory (module-level variable) with a short TTL (e.g. 60 seconds) to reduce read RUs on warm instances.

---

## 4. APIM Policy Debugging and Trace Mode

**Triggered by:** Unexpected 4xx responses from APIM, or incorrect request transformation behaviour.

**Investigation steps:**

1. In the **Azure Portal → APIM → APIs → Enquiry Hub API**, click **Test** on the affected operation.
2. Enable **Ocp-Apim-Trace: true** in the test request headers. APIM will return a `Ocp-Apim-Trace-Location` header in the response with a URL to the full trace.
3. Open the trace URL — it shows the full inbound/backend/outbound policy execution with each step's input/output and any policy exceptions.

**Common issues and fixes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| 401 on valid key | Subscription key not in the expected header (`Ocp-Apim-Subscription-Key`) | Confirm the client is sending the header, not a query parameter |
| 404 from APIM | Operation URL template mismatch | Check the route pattern in APIM → APIs → Design |
| 502 Bad Gateway | Function App host URL incorrect in the APIM backend | APIM → Backends → verify the function host URL |
| 503 after deploy | APIM cache still has old backend config | Clear the APIM cache via Portal or `az apim cache` |

**To add tracing permanently** (for dev only — never in prod, as traces contain request bodies):

In the APIM inbound policy, add: `<trace source="enquiry-hub" severity="verbose">...</trace>`

Traces appear in **Application Insights → Traces** with source `apim`.

---

## 5. Incident Response Workflow

**Severity classification:**

| Severity | Definition | Example |
|---|---|---|
| P1 — Critical | System unavailable or data loss in progress | All enquiries failing to process; DLQ filling rapidly |
| P2 — High | Degraded functionality affecting users | Chat endpoint returning 500s; Critical alert emails not sending |
| P3 — Medium | Minor degradation, workaround exists | Cold-start latency; occasional 429 throttle |

**Response steps:**

1. **Detect** — Alert fires to `easy@alphaio.com.au`, or a user reports an issue.
2. **Triage** — Check Application Insights Failures blade and the three KQL queries in `docs/kql-queries.md`. Determine which function and which downstream dependency is involved.
3. **Contain** — For P1: consider temporarily disabling the APIM `/submit` endpoint to stop new enquiries from being queued while the issue is resolved.
4. **Investigate** — Use the relevant section of this runbook (DLQ, scaling, Cosmos, APIM). Check Sentinel analytics rule incidents in **Microsoft Sentinel → Incidents**.
5. **Resolve** — Apply the fix (code change, configuration update, or infrastructure change via Terraform).
6. **Recover** — Replay any dead-lettered messages (see Section 1). Verify alert auto-mitigates or manually resolve it in Azure Monitor.
7. **Post-mortem** — Document in a GitHub issue: timeline, root cause, impact, fix, and prevention steps. Update this runbook if a new failure mode was encountered.

**Key contacts and links:**

- Azure Portal: `portal.azure.com` → Resource group `rg-enquiryhub-dev`
- Application Insights: search for `appi-enquiryhub-dev`
- Sentinel incidents: Log Analytics workspace `law-enquiryhub-dev` → Microsoft Sentinel → Incidents
- GitHub Actions (deployment status): repository → Actions tab
- Alert notifications: `easy@alphaio.com.au`
