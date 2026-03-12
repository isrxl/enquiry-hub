# ─────────────────────────────────────────────────────────────────────────────
# Root-level metric alert rules
#
# These resources live at the root (not inside a module) to avoid a circular
# dependency between the monitoring and compute modules.  Root resources can
# freely reference outputs from both modules.
#
# Each alert is scoped to a specific resource ID — Azure Monitor metric alerts
# do NOT support resource-group-level scoping for most resource types
# (Microsoft.Web/sites, Microsoft.DocumentDB/databaseAccounts,
# Microsoft.ServiceBus/namespaces, Microsoft.ApiManagement/service).
# ─────────────────────────────────────────────────────────────────────────────

# Alert: Function App execution failures > 5 in a 5-minute window.
# Http5xx catches 500-range responses from all three HTTP-triggered functions.
resource "azurerm_monitor_metric_alert" "function_failures" {
  name                = "alert-fn-failures-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.compute.function_app_id]
  description         = "Fires when the Function App returns more than 5 HTTP 5xx responses in 5 minutes."
  severity            = 2 # Warning

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5
  }

  window_size   = "PT5M"
  frequency     = "PT1M"
  auto_mitigate = true

  action {
    action_group_id = module.monitoring.action_group_id
  }
}

# Alert: Cosmos DB 429 (throttled) requests > 10 in 5 minutes.
# Indicates the serverless RU budget is being exhausted; consider capacity tuning.
resource "azurerm_monitor_metric_alert" "cosmos_throttled" {
  name                = "alert-cosmos-throttle-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.data.cosmosdb_id]
  description         = "Fires when Cosmos DB returns more than 10 throttled (429) requests in 5 minutes."
  severity            = 2

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "TotalRequestUnits"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10

    dimension {
      name     = "StatusCode"
      operator = "Include"
      values   = ["429"]
    }
  }

  window_size   = "PT5M"
  frequency     = "PT1M"
  auto_mitigate = true

  action {
    action_group_id = module.monitoring.action_group_id
  }
}

# Alert: Service Bus dead-letter queue depth > 0.
# Any message in the DLQ means processing has failed beyond the retry limit.
# Only created when messaging_path uses Service Bus (sb_id is non-null).
# auto_mitigate = false — DLQ messages require manual investigation and replay.
resource "azurerm_monitor_metric_alert" "servicebus_dlq" {
  count               = module.messaging.sb_id != null ? 1 : 0
  name                = "alert-sb-dlq-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.messaging.sb_id]
  description         = "Fires when the Service Bus dead-letter queue contains at least one message."
  severity            = 1 # Error

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadLetteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 0
  }

  window_size   = "PT5M"
  frequency     = "PT1M"
  auto_mitigate = false

  action {
    action_group_id = module.monitoring.action_group_id
  }
}

# Alert: APIM 4xx/5xx error rate > 10 in 5 minutes.
# A sustained error rate indicates misconfiguration, an outage, or an attack.
resource "azurerm_monitor_metric_alert" "apim_errors" {
  name                = "alert-apim-errors-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.compute.apim_id]
  description         = "Fires when APIM returns more than 10 4xx or 5xx responses in 5 minutes."
  severity            = 2 # Warning

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10

    dimension {
      name     = "GatewayResponseCodeCategory"
      operator = "Include"
      values   = ["4xx", "5xx"]
    }
  }

  window_size   = "PT5M"
  frequency     = "PT1M"
  auto_mitigate = true

  action {
    action_group_id = module.monitoring.action_group_id
  }
}
