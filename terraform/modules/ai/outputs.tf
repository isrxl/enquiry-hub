output "openai_endpoint" {
  description = "Azure OpenAI account endpoint URL. Passed to the Function App as OPENAI_ENDPOINT."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "openai_id" {
  description = "Azure OpenAI account resource ID. Used by rbac.tf to scope the Cognitive Services OpenAI User role."
  value       = azurerm_cognitive_account.openai.id
}
