# ─────────────────────────────────────────────────────────────────────────────
# Root Terraform configuration.
# Wires all child modules together and provisions the shared resource group.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Remote state stored in the Azure Storage Account created in pre-requisites.
  # Update storage_account_name to match your TFSTATE_STORAGE_NAME value.
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "enquiryhubx7qp9mk"
    container_name       = "tfstate"
    key                  = "enquiry-hub.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      # Allow resource group deletion even when auto-created resources exist
      # (e.g. "Failure Anomalies" smart detector rules created by App Insights).
      prevent_deletion_if_contains_resources = false # change to true after dev cleanup to prevent accidental RG deletion in the future
    }
    key_vault {
      # Allow Key Vault deletion without purging secrets first.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
  # Authentication is handled via OIDC in CI (ARM_* env vars).
  # Locally, run `az login` and set ARM_SUBSCRIPTION_ID.
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared resource group — all resources are deployed into this group.
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: networking
# Provisions the VNET and subnets used by all other modules.
# Must be called first — its outputs are consumed by every other module.
# ─────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "./modules/networking"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: messaging
# Provisions Service Bus (standard/premium) or Storage Queue depending on
# the messaging_path variable. Private endpoint created for premium/storagequeue.
# ─────────────────────────────────────────────────────────────────────────────
module "messaging" {
  source = "./modules/messaging"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  messaging_path      = var.messaging_path

  # Networking outputs required for private endpoint placement
  vnet_id    = module.networking.vnet_id
  pe_subnet_id = module.networking.pe_subnet_id
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: data
# Provisions Cosmos DB (Serverless) with a private endpoint.
# ─────────────────────────────────────────────────────────────────────────────
module "data" {
  source = "./modules/data"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  vnet_id      = module.networking.vnet_id
  pe_subnet_id = module.networking.pe_subnet_id
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: ai
# Provisions Azure OpenAI with the specified model and a private endpoint.
# ─────────────────────────────────────────────────────────────────────────────
module "ai" {
  source = "./modules/ai"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  openai_model        = var.openai_model

  vnet_id      = module.networking.vnet_id
  pe_subnet_id = module.networking.pe_subnet_id
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: security
# Provisions Key Vault with RBAC authorization enabled.
# ─────────────────────────────────────────────────────────────────────────────
module "security" {
  source = "./modules/security"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: monitoring
# Provisions Log Analytics workspace and Application Insights.
# ─────────────────────────────────────────────────────────────────────────────
module "monitoring" {
  source = "./modules/monitoring"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  alert_email         = var.alert_email
}

# ─────────────────────────────────────────────────────────────────────────────
# Module: compute
# Provisions Function App, APIM, Event Grid, and the Azure Static Web App.
# Receives outputs from all other modules to wire up app settings and RBAC.
# ─────────────────────────────────────────────────────────────────────────────
module "compute" {
  source = "./modules/compute"

  # Ensures the Key Vault Secrets Officer role assignment (in the security module)
  # exists before the compute module attempts to write azurerm_key_vault_secret.
  # Azure RBAC propagation can lag a few minutes; explicit ordering reduces races.
  depends_on = [module.security, module.networking]

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  # Networking
  functions_subnet_id = module.networking.functions_subnet_id
  apim_subnet_id      = module.networking.apim_subnet_id

  # Messaging — values are null when the path is not active
  messaging_path        = var.messaging_path
  sb_fqdn               = module.messaging.sb_fqdn
  sb_id                 = module.messaging.sb_id
  queue_conn_string     = module.messaging.queue_conn_string

  # Data
  cosmosdb_endpoint      = module.data.cosmosdb_endpoint
  cosmosdb_id            = module.data.cosmosdb_id
  cosmosdb_account_name  = module.data.cosmosdb_account_name

  # AI
  openai_endpoint    = module.ai.openai_endpoint
  openai_id          = module.ai.openai_id
  openai_model       = var.openai_model

  # Security
  keyvault_id          = module.security.keyvault_id
  apim_publisher_email = var.apim_publisher_email

  # Monitoring
  ai_connection_string     = module.monitoring.ai_connection_string
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  # External Entra app registration for SWA authentication
  swa_auth_client_id     = var.swa_auth_client_id
  swa_auth_client_secret = var.swa_auth_client_secret
  swa_auth_tenant_id     = var.swa_auth_tenant_id
}
