# ─────────────────────────────────────────────────────────────────────────────
# RBAC assignments for the Function App's system-assigned managed identity.
#
# Managed identity eliminates stored credentials entirely. Each role is scoped
# to the minimum resource necessary (least-privilege principle).
#
# Role propagation in Azure AD can take 2–5 minutes; the Function App may
# return 403 errors briefly after a fresh deploy while roles propagate.
# ─────────────────────────────────────────────────────────────────────────────

# ── Service Bus: Data Receiver + Sender (paths A & B only) ───────────────────
# count is derived from var.messaging_path (a static variable known at plan time)
# rather than var.sb_id (a resource attribute only known after apply), which
# avoids the "count depends on resource attributes" Terraform error.

locals {
  is_service_bus = contains(["standard", "premium"], var.messaging_path)
}

resource "azurerm_role_assignment" "sb_data_receiver" {
  count = local.is_service_bus ? 1 : 0

  scope                = var.sb_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "sb_data_sender" {
  count = local.is_service_bus ? 1 : 0

  scope                = var.sb_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

# ── Cosmos DB: Built-in Data Contributor ─────────────────────────────────────
# azurerm_cosmosdb_sql_role_assignment is used instead of
# azurerm_role_assignment because Cosmos DB uses its own RBAC plane
# (not Azure RBAC), with built-in role IDs defined per account.
# Role ID 00000000-0000-0000-0000-000000000002 = "Cosmos DB Built-in Data Contributor"

resource "azurerm_cosmosdb_sql_role_assignment" "function_app" {
  resource_group_name = var.resource_group_name
  account_name        = var.cosmosdb_account_name
  role_definition_id  = "${var.cosmosdb_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_linux_function_app.main.identity[0].principal_id

  # Scope to the full account so the identity can access any database/container.
  scope = var.cosmosdb_id
}

# ── Azure OpenAI: Cognitive Services OpenAI User ──────────────────────────────
# Grants the identity permission to call the inference endpoint.
# The openai Python SDK uses azure_ad_token_provider with DefaultAzureCredential
# which picks up the managed identity automatically in Azure.

resource "azurerm_role_assignment" "openai_user" {
  scope                = var.openai_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

# ── Key Vault: Secrets User ───────────────────────────────────────────────────
# Allows the Function App to read secrets stored in Key Vault at runtime.

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.keyvault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

# ── Event Grid: Data Sender ───────────────────────────────────────────────────
# Allows the Function App to publish events to the Critical enquiry topic.
# The function uses managed identity (DefaultAzureCredential) rather than the
# topic key, which eliminates a Key Vault lookup on every Critical enquiry.

resource "azurerm_role_assignment" "eventgrid_sender" {
  scope                = azurerm_eventgrid_topic.critical.id
  role_definition_name = "EventGrid Data Sender"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}
