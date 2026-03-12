# ─────────────────────────────────────────────────────────────────────────────
# Action group — notifies on-call email for all Azure Monitor alert rules.
#
# Metric alert rules are defined in the root terraform/alerts.tf rather than
# here to avoid a circular dependency:
#   monitoring module → compute (for function_app_id / apim_id)
#   compute module    → monitoring (for ai_connection_string / workspace_id)
#
# Root-level resources can reference outputs from both modules freely.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_monitor_action_group" "default" {
  name                = "ag-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "enquiryhub"

  email_receiver {
    name          = "oncall"
    email_address = var.alert_email
  }
}
