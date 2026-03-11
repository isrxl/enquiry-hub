# KQL Queries — Enquiry Hub

Paste these queries into **Log Analytics workspace → Logs** (or the Application Insights **Logs** blade).
All queries target the workspace created by `terraform/modules/monitoring/main.tf`.

---

## 1. Function Execution Latency (p50 / p95 / p99)

Shows end-to-end duration of every Function invocation over the last 24 hours,
broken down by function name with percentile statistics.
Use this to identify slow executions and set alert thresholds.

```kql
requests
| where timestamp > ago(24h)
| where cloud_RoleName startswith "func-enquiryhub"
| summarize
    p50   = percentile(duration, 50),
    p95   = percentile(duration, 95),
    p99   = percentile(duration, 99),
    count = count()
  by name
| order by p95 desc
```

### Key columns

| Column | Meaning                                                              |
|--------|----------------------------------------------------------------------|
| `name` | Function name (`process_enquiry`, `submit_enquiry`, `chat_endpoint`) |
| `p50`  | Median latency in milliseconds                                       |
| `p95`  | 95th-percentile — a good SLO target                                  |
| `p99`  | Tail latency; spikes here often indicate cold starts or throttling   |

---

## 2. Enquiry Volume by Category and Urgency

Counts enquiries classified and written to Cosmos DB, grouped by AI-assigned
`category` and `urgency`.  Because `process_enquiry` logs a structured custom
event for every enquiry processed, this query gives a live breakdown of
enquiry types across any time window.

```kql
customEvents
| where timestamp > ago(7d)
| where name == "EnquiryProcessed"
| extend
    category = tostring(customDimensions["category"]),
    urgency  = tostring(customDimensions["urgency"])
| summarize count() by category, urgency
| order by count_ desc
```

> **Prerequisite:** `function_app.py` emits `EnquiryProcessed` via
> `logging.info` with structured properties captured by the Application
> Insights Python SDK.  If you replace the logger with `track_event()`,
> change the `name` filter to match your event name.

Suggested visualisation: stacked bar chart — X axis = `category`,
series = `urgency`, Y axis = `count_`.

---

## 3. Failed Operations (Errors and Exceptions)

Surfaces all failed requests and unhandled exceptions across the Function App,
bucketed into 5-minute windows so you can spot error bursts at a glance.

```kql
union
    (
        requests
        | where timestamp > ago(6h)
        | where success == false
        | project timestamp, operation = name, detail = resultCode, type = "request_failure"
    ),
    (
        exceptions
        | where timestamp > ago(6h)
        | project timestamp, operation = operation_Name, detail = outerMessage, type = "exception"
    )
| summarize
    error_count   = count(),
    sample_detail = any(detail)
  by bin(timestamp, 5m), operation, type
| order by timestamp desc
```

### Reading the output

| `type`             | Cause                                                              |
|--------------------|--------------------------------------------------------------------|
| `request_failure`  | HTTP 4xx / 5xx from `submit_enquiry` or `chat_endpoint`            |
| `exception`        | Unhandled Python exception (Cosmos write failure, OpenAI timeout)  |

Pin this query as a workbook tile with a rolling 6-hour time range for an
at-a-glance operations dashboard.
