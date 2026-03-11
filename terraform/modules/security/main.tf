# ─────────────────────────────────────────────────────────────────────────────
# Security module — Azure Key Vault
#
# Provisions a Key Vault with RBAC authorization enabled.
# The Event Grid topic key is stored here by the compute module
# (azurerm_key_vault_secret), and retrieved at runtime by the Function App
# via the "Key Vault Secrets User" role assigned in compute/rbac.tf.
#
# RBAC mode is preferred over access policies because it integrates with
# Azure AD Conditional Access and is auditable through Azure Monitor.
# ─────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "kv-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC authorization replaces the legacy access-policy model.
  # Role assignments are managed in compute/rbac.tf.
  enable_rbac_authorization = true

  # Soft-delete protects against accidental or malicious deletion.
  # retention_days defaults to 90; must be between 7 and 90.
  soft_delete_retention_days = 90
  purge_protection_enabled   = true
}
