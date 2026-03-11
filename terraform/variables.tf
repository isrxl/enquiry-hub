# ─────────────────────────────────────────────────────────────────────────────
# Root-level input variables.
# Copy terraform.tfvars.example → terraform.tfvars and supply your own values.
# terraform.tfvars is gitignored; never commit it.
# ─────────────────────────────────────────────────────────────────────────────

variable "project_name" {
  type        = string
  default     = "enquiryhub"
  description = "Short name used as a prefix for all Azure resource names."
}

variable "location" {
  type        = string
  default     = "australiaeast"
  description = "Azure region for all resources."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment label (dev / staging / prod)."
}

variable "messaging_path" {
  type        = string
  default     = "standard"
  description = <<EOT
Controls which messaging backend is provisioned:
  standard     – Azure Service Bus Standard SKU (default, cheapest)
  premium      – Azure Service Bus Premium SKU + private endpoint
  storagequeue – Azure Storage Queue + private endpoint
EOT

  validation {
    condition     = contains(["standard", "premium", "storagequeue"], var.messaging_path)
    error_message = "messaging_path must be one of: standard, premium, storagequeue."
  }
}

variable "openai_model" {
  type        = string
  default     = "gpt-4o"
  description = "Azure OpenAI model to deploy (e.g. gpt-4o, gpt-35-turbo)."
}

variable "apim_publisher_email" {
  type        = string
  default     = "admin@example.com"
  description = "Contact email shown in the APIM publisher profile. Set this in terraform.tfvars."
}

variable "alert_email" {
  type        = string
  default     = "admin@example.com"
  description = "Email address for Azure Monitor and Sentinel alert notifications."
}
