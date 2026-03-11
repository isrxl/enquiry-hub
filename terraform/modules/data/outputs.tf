output "cosmosdb_endpoint" {
  description = "Cosmos DB account endpoint URL. Passed to the Function App as COSMOS_ENDPOINT."
  value       = azurerm_cosmosdb_account.main.endpoint
}

output "cosmosdb_id" {
  description = "Cosmos DB account resource ID. Used by rbac.tf to scope the built-in data contributor role."
  value       = azurerm_cosmosdb_account.main.id
}

output "cosmosdb_account_name" {
  description = "Cosmos DB account name. Required by azurerm_cosmosdb_sql_role_assignment in compute/rbac.tf."
  value       = azurerm_cosmosdb_account.main.name
}
