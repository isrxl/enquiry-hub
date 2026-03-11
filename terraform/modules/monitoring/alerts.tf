# ─────────────────────────────────────────────────────────────────────────────
# Azure Monitor alert rules
#
# These metric alerts fire when key thresholds are breached.
# Notification targets (action groups with email/Teams webhooks) should be
# added to azurerm_monitor_action_group and wired into each alert's
# `action` block once an on-call contact is known.
# ─────────────────────────────────────────────────────────────────────────────

# Action group — notifies on-call email for all alert rules in this module.
resource "azurerm_monitor_action_group" "default" {
  name                = "ag-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "enquiryhub"

  email_receiver {
    name          = "oncall"
    email_address = var.alert_email
  }
}

# Alert: Function App failures > 5 in a 5-minute window
# Catches processing errors in process_enquiry / submit_enquiry / chat_endpoint.
resource "azurerm_monitor_metric_alert" "function_failures" {
  name                = "alert-fn-failures-${var.environment}"
  resource_group_name = var.resource_group_name

  # Scope is set to the resource group so the alert covers all Function Apps.
  # Narrow this to a specific Function App resource ID after compute deploys.
  scopes = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"]

  description = "Fires when Function App failures exceed 5 in 5 minutes."
  severity    = 2 # Warning

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "FunctionExecutionCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5

    dimension {
      name     = "FunctionName"
      operator = "Include"
      values   = ["*"]
    }
  }

  window_size        = "PT5M"
  frequency          = "PT1M"
  auto_mitigate      = true

  action {
    action_group_id = azurerm_monitor_action_group.default.id
  }
}

# Alert: Cosmos DB 429 (throttled) requests > 10 in 5 minutes
# Indicates the serverless RU budget is being exhausted; consider capacity tuning.
resource "azurerm_monitor_metric_alert" "cosmos_throttled" {
  name                = "alert-cosmos-throttle-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"]
  description         = "Fires when Cosmos DB returns >10 throttled requests in 5 minutes."
  severity            = 2

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "TotalRequestUnits"
    aggregation      = "Count"
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
    action_group_id = azurerm_monitor_action_group.default.id
  }
}

# Alert: Service Bus dead-letter queue depth > 0
# Any message in the DLQ means processing has failed beyond the retry limit.
# auto_mitigate = false — DLQ messages require manual investigation and replay;
# the alert must be resolved explicitly, not dismissed when depth drops.
resource "azurerm_monitor_metric_alert" "servicebus_dlq" {
  name                = "alert-sb-dlq-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"]
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
    action_group_id = azurerm_monitor_action_group.default.id
  }
}

# Alert: APIM 4xx/5xx error rate > 10 in 5 minutes
# Uses GatewayResponseCodeCategory dimension to match all 4xx and 5xx responses.
# A sustained error rate indicates misconfiguration, an outage, or an attack.
resource "azurerm_monitor_metric_alert" "apim_errors" {
  name                = "alert-apim-errors-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"]
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
    action_group_id = azurerm_monitor_action_group.default.id
  }
}

# Data source required to build the subscription-level scope strings above.
data "azurerm_subscription" "current" {}
