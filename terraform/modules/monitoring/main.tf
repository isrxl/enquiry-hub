# ─────────────────────────────────────────────────────────────────────────────
# Monitoring module
#
# Provisions:
#   • Log Analytics workspace  (PerGB2018 pricing, 90-day retention)
#   • Application Insights     (workspace-based, linked to Log Analytics)
#   • Microsoft Sentinel       (onboarded to the workspace above)
#   • Sentinel analytics rules (APIM auth failures, request spike, RBAC changes)
#
# The App Insights connection string is injected into the Function App as
# APPLICATIONINSIGHTS_CONNECTION_STRING so the SDK auto-configures telemetry.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # PerGB2018: pay-per-GB ingestion with no commitment tier required.
  sku               = "PerGB2018"
  retention_in_days = 90 # 90 days covers incident investigation windows; adjust for prod
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # "web" application type configures the correct default dashboards and
  # availability test options for HTTP-based workloads.
  application_type = "web"

  # Workspace-based mode sends all telemetry to Log Analytics, enabling
  # cross-resource KQL queries across Functions, Cosmos DB, and APIM logs.
  workspace_id = azurerm_log_analytics_workspace.main.id
}

# ── Microsoft Sentinel ────────────────────────────────────────────────────────
#
# Onboards the Log Analytics workspace to Sentinel (free tier — no Defender
# plan required). APIM and Function App diagnostic logs flow into this workspace
# via diagnostic settings configured in the compute module, making them
# queryable by the analytics rules below.
#
# NOTE: Foundational CSPM does not include Defender workload protection alerts.
# The analytics rules below use custom KQL to provide equivalent coverage for
# the specific threats in the Enquiry Hub threat model.

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  workspace_id = azurerm_log_analytics_workspace.main.id
}

# ── Analytics rule 1: APIM authentication failure spike ──────────────────────
# Fires when a single IP triggers more than 20 APIM 401 responses in one hour.
# Indicates either a brute-force subscription key attack or a misconfigured
# integration. Maps to Threat 2 (keyless APIM calls) in the threat model.

resource "azurerm_sentinel_alert_rule_scheduled" "apim_auth_failures" {
  name                       = "apim-auth-failure-spike"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  display_name               = "APIM Authentication Failure Spike"
  severity                   = "Medium"
  enabled                    = true

  query = <<-KQL
    ApiManagementGatewayLogs
    | where TimeGenerated > ago(1h)
    | where ResponseCode == 401
    | summarize AuthFailures = count() by CallerIpAddress
    | where AuthFailures > 20
  KQL

  query_frequency   = "PT1H"
  query_period      = "PT1H"
  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# ── Analytics rule 2: APIM request volume spike (potential DoS) ──────────────
# Fires when any 1-minute window contains more than 100 APIM requests.
# The Developer SKU APIM has no SLA; a sudden spike can exhaust the Consumption
# plan. Maps to Threat 13 (APIM endpoint flooding) in the threat model.

resource "azurerm_sentinel_alert_rule_scheduled" "apim_request_spike" {
  name                       = "apim-request-volume-spike"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  display_name               = "APIM Request Volume Spike (Potential DoS)"
  severity                   = "High"
  enabled                    = true

  query = <<-KQL
    ApiManagementGatewayLogs
    | where TimeGenerated > ago(15m)
    | summarize RequestCount = count() by bin(TimeGenerated, 1m)
    | where RequestCount > 100
  KQL

  query_frequency   = "PT15M"
  query_period      = "PT15M"
  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

# ── Analytics rule 3: Unexpected RBAC change ─────────────────────────────────
# Fires on any successful role assignment or deletion not performed via the
# normal Terraform CI/CD pipeline. Alerts the team to review whether the
# change was authorised. Maps to Threat 16 (privilege escalation) in the
# threat model.

resource "azurerm_sentinel_alert_rule_scheduled" "rbac_change" {
  name                       = "unexpected-rbac-change"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  display_name               = "Unexpected RBAC Role Assignment Change"
  severity                   = "High"
  enabled                    = true

  query = <<-KQL
    AzureActivity
    | where TimeGenerated > ago(1h)
    | where OperationNameValue has_any (
        "Microsoft.Authorization/roleAssignments/write",
        "Microsoft.Authorization/roleAssignments/delete"
      )
    | where ActivityStatusValue == "Success"
    | project TimeGenerated, Caller, OperationNameValue, ResourceGroup, _ResourceId
  KQL

  query_frequency   = "PT1H"
  query_period      = "PT1H"
  trigger_operator  = "GreaterThan"
  trigger_threshold = 0

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}
