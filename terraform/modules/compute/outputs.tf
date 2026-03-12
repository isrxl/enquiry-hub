output "function_app_name" {
  description = "Function App name. Use this in .github/workflows/app.yml after Terraform apply."
  value       = azurerm_linux_function_app.main.name
}

output "function_app_id" {
  description = "Function App resource ID. Can be used for diagnostic settings or policy assignments."
  value       = azurerm_linux_function_app.main.id
}

output "apim_id" {
  description = "APIM resource ID. Referenced by root-level metric alert rules."
  value       = azurerm_api_management.main.id
}

output "apim_gateway_url" {
  description = "APIM gateway URL (base URL for external API calls)."
  value       = "https://${azurerm_api_management.main.gateway_url}"
}

output "web_endpoint" {
  description = "Azure Static Web App URL for the staff chatbot. Share this with staff after deployment."
  value       = "https://${azurerm_static_web_app.main.default_host_name}"
}

output "swa_auth_callback_url" {
  description = "Redirect URI to add to the external Entra app registration for SWA authentication."
  value       = "https://${azurerm_static_web_app.main.default_host_name}/.auth/login/aad/callback"
}

# The deployment token authenticates the GitHub Actions SWA deploy action.
# After Terraform apply, store this as a GitHub secret:
#   gh secret set SWA_DEPLOYMENT_TOKEN --body "$(terraform output -raw swa_deployment_token)"
output "swa_deployment_token" {
  description = "SWA deployment token. Store as GitHub secret SWA_DEPLOYMENT_TOKEN."
  value       = azurerm_static_web_app.main.api_key
  sensitive   = true
}
