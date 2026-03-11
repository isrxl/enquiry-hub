variable "project_name" {
  type        = string
  description = "Short name prefix for all resources."
}

variable "environment" {
  type        = string
  description = "Deployment environment label."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy into."
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "functions_subnet_id" {
  type        = string
  description = "Subnet ID for Function App VNET integration (outbound traffic)."
}

variable "apim_subnet_id" {
  type        = string
  description = "Subnet ID dedicated to API Management."
}

# ── Messaging ─────────────────────────────────────────────────────────────────

variable "messaging_path" {
  type        = string
  description = "Active messaging path: standard | premium | storagequeue."
}

variable "sb_fqdn" {
  type        = string
  nullable    = true
  description = "Service Bus namespace FQDN. Null when messaging_path = storagequeue."
}

variable "sb_id" {
  type        = string
  nullable    = true
  description = "Service Bus namespace resource ID. Null when messaging_path = storagequeue."
}

variable "queue_conn_string" {
  type        = string
  nullable    = true
  sensitive   = true
  description = "Storage Account connection string for queue trigger. Null for Service Bus paths."
}

# ── Data ──────────────────────────────────────────────────────────────────────

variable "cosmosdb_endpoint" {
  type        = string
  description = "Cosmos DB account endpoint URL."
}

variable "cosmosdb_id" {
  type        = string
  description = "Cosmos DB account resource ID (used for RBAC scoping)."
}

variable "cosmosdb_account_name" {
  type        = string
  description = "Cosmos DB account name (required for sql_role_assignment)."
}

# ── AI ────────────────────────────────────────────────────────────────────────

variable "openai_endpoint" {
  type        = string
  description = "Azure OpenAI account endpoint URL."
}

variable "openai_id" {
  type        = string
  description = "Azure OpenAI account resource ID (used for RBAC scoping)."
}

variable "openai_model" {
  type        = string
  description = "Deployment name of the Azure OpenAI model (matches azurerm_cognitive_deployment.name)."
}

# ── Security ──────────────────────────────────────────────────────────────────

variable "keyvault_id" {
  type        = string
  description = "Key Vault resource ID (used for RBAC scoping and secret storage)."
}

# ── Monitoring ────────────────────────────────────────────────────────────────

variable "ai_connection_string" {
  type        = string
  sensitive   = true
  description = "Application Insights connection string."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics workspace resource ID (used for diagnostic settings)."
}

variable "apim_publisher_email" {
  type        = string
  default     = "admin@example.com"
  description = "Email address for the APIM publisher contact. Set this in terraform.tfvars."
}
