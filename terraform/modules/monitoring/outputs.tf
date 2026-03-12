output "ai_connection_string" {
  description = "Application Insights connection string. Set as APPLICATIONINSIGHTS_CONNECTION_STRING in the Function App."
  sensitive   = true
  value       = azurerm_application_insights.main.connection_string
}

output "ai_instrumentation_key" {
  description = "Application Insights instrumentation key. Retained for legacy SDK compatibility."
  sensitive   = true
  value       = azurerm_application_insights.main.instrumentation_key
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID. Used by alerts.tf and diagnostic settings."
  value       = azurerm_log_analytics_workspace.main.id
}

output "action_group_id" {
  description = "Default action group resource ID. Referenced by root-level metric alert rules."
  value       = azurerm_monitor_action_group.default.id
}
