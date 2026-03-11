output "keyvault_id" {
  description = "Key Vault resource ID. Used by compute/rbac.tf to scope the Key Vault Secrets User role."
  value       = azurerm_key_vault.main.id
}
