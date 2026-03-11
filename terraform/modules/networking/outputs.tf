output "vnet_id" {
  description = "Resource ID of the virtual network. Passed to modules that create private DNS zone VNET links."
  value       = azurerm_virtual_network.main.id
}

output "functions_subnet_id" {
  description = "Subnet ID for Function App VNET integration."
  value       = azurerm_subnet.functions.id
}

output "pe_subnet_id" {
  description = "Subnet ID for private endpoints (Cosmos DB, Service Bus, OpenAI, etc.)."
  value       = azurerm_subnet.private_endpoints.id
}

output "apim_subnet_id" {
  description = "Subnet ID dedicated to API Management."
  value       = azurerm_subnet.apim.id
}
