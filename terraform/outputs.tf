# ─────────────────────────────────────────────────────────────────────────────
# Root-level outputs — surfaced after `terraform apply`.
# Run `terraform output` to retrieve these values for post-deploy steps.
# ─────────────────────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the main Azure resource group."
  value       = azurerm_resource_group.main.name
}

output "function_app_name" {
  description = "Name of the Azure Function App. Use this in .github/workflows/app.yml."
  value       = module.compute.function_app_name
}

output "apim_gateway_url" {
  description = "APIM gateway URL for external API access."
  value       = module.compute.apim_gateway_url
}

output "web_endpoint" {
  description = "Azure Static Web App URL for the staff chatbot. Share with staff after deployment."
  value       = module.compute.web_endpoint
}

output "swa_auth_callback_url" {
  description = "Redirect URI to add to the external Entra app registration for SWA authentication."
  value       = module.compute.swa_auth_callback_url
}

# Run after Terraform apply to store the token as a GitHub secret:
#   gh secret set SWA_DEPLOYMENT_TOKEN --body "$(terraform output -raw swa_deployment_token)"
output "swa_deployment_token" {
  description = "SWA deployment token. Store as GitHub secret SWA_DEPLOYMENT_TOKEN."
  value       = module.compute.swa_deployment_token
  sensitive   = true
}
