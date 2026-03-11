# Outputs are nullable — the compute module guards against null with `count` or conditionals.

output "sb_fqdn" {
  description = "Service Bus namespace FQDN (paths A & B). Null for storagequeue path."
  value       = local.is_service_bus ? "${azurerm_servicebus_namespace.main[0].name}.servicebus.windows.net" : null
}

output "sb_id" {
  description = "Service Bus namespace resource ID (paths A & B). Null for storagequeue path."
  value       = local.is_service_bus ? azurerm_servicebus_namespace.main[0].id : null
}

output "queue_conn_string" {
  description = "Storage Account primary connection string (path C only). Null for Service Bus paths."
  sensitive   = true
  value       = local.is_storage_queue ? azurerm_storage_account.queue[0].primary_connection_string : null
}

output "messaging_path" {
  description = "Passes the active messaging_path through so compute module can reference it."
  value       = var.messaging_path
}
