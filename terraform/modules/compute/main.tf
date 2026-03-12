# ─────────────────────────────────────────────────────────────────────────────
# Compute module
#
# Provisions all application-layer resources:
#   • Storage Account         — Azure Functions runtime storage
#   • Service Plan            — Linux Consumption (Y1)
#   • Linux Function App      — Python 3.11, VNET-integrated, managed identity
#   • API Management          — Developer SKU; import Function App after deploy
#   • Event Grid Topic        — Critical enquiry alerts
#   • Key Vault Secret        — Stores Event Grid topic key
#   • Storage Account (web)   — Static website hosting for staff chatbot
# ─────────────────────────────────────────────────────────────────────────────

# ── Functions runtime storage ─────────────────────────────────────────────────
# A dedicated storage account is required by the Functions host for
# internal state (leases, timers, logs). Keep separate from the web storage.

resource "azurerm_storage_account" "functions" {
  name                     = "stfn${replace(var.project_name, "-", "")}${var.environment}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  allow_nested_items_to_be_public = false
}

# ── Service Plan — Linux Basic (B1) ──────────────────────────────────────────
# B1 = dedicated Basic tier; required for regional VNet integration on Linux.
# The Linux Consumption plan (Y1) does NOT support VNet integration, so B1 is
# the lowest-cost SKU that allows the Function App to reach private endpoints.
# Approx. cost: ~$13 AUD/month. Upgrade to EP1 for auto-scaling in production.

resource "azurerm_service_plan" "main" {
  name                = "asp-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# ── Linux Function App ────────────────────────────────────────────────────────

resource "azurerm_linux_function_app" "main" {
  name                       = "func-${var.project_name}-${var.environment}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.functions.name
  storage_account_access_key = azurerm_storage_account.functions.primary_access_key

  # System-assigned managed identity eliminates the need for stored credentials.
  # The identity's principal_id is used by rbac.tf to assign all data-plane roles.
  identity {
    type = "SystemAssigned"
  }

  # Route all outbound Function traffic through the VNET so it can reach
  # private endpoints for Cosmos DB, Service Bus, and OpenAI.
  virtual_network_subnet_id = var.functions_subnet_id

  site_config {
    # vnet_route_all_enabled ensures DNS resolution uses the VNET's private DNS
    # zones rather than public Azure DNS, which is critical for private endpoints.
    vnet_route_all_enabled = true

    application_stack {
      python_version = "3.11"
    }

    # ── Inbound access restrictions ──────────────────────────────────────────
    # NOTE: "AzureStaticWebApps" is NOT a valid service tag for App Service
    # ip_restriction (it is only valid in NSG rules). Because the SWA linked
    # backend IP range cannot be expressed as a valid App Service service tag,
    # IP-level restriction is not applied here.
    #
    # Access control is enforced via:
    #   • auth_level = FUNCTION on every endpoint (function key required)
    #   • APIM subscription key for the external /submit path
    #   • SWA Entra ID auth (HttpOnly cookie) for the /api/chat path
    #   • VNET outbound routing — Function App reaches private endpoints only
  }

  app_settings = {
    # ── Cosmos DB ──────────────────────────────────────────────────────────
    COSMOS_ENDPOINT   = var.cosmosdb_endpoint
    COSMOS_DATABASE   = "EnquiryHub"
    COSMOS_CONTAINER  = "Enquiries"

    # ── Azure OpenAI ───────────────────────────────────────────────────────
    OPENAI_ENDPOINT   = var.openai_endpoint
    OPENAI_DEPLOYMENT = var.openai_model

    # ── Application Insights ───────────────────────────────────────────────
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.ai_connection_string

    # ── Messaging: Service Bus (paths A & B) ───────────────────────────────
    # SERVICE_BUS_FQDN is used by the ServiceBusClient in function_app.py.
    # Null when messaging_path = storagequeue; the trigger decorator is
    # commented out in that case anyway (see function_app.py).
    SERVICE_BUS_FQDN  = var.sb_fqdn
    SERVICE_BUS_QUEUE = "enquiry-queue"

    # ── Messaging: Storage Queue (path C) ──────────────────────────────────
    # AzureWebJobsQueueStorage is the connection setting name expected by the
    # Azure Functions Storage Queue trigger binding.
    AzureWebJobsQueueStorage = var.queue_conn_string

    # ── Messaging path — controls trigger registration in function_app.py ──
    # function_app.py reads MESSAGING_PATH at import time to register either
    # the Service Bus or Storage Queue trigger variant (never both).
    MESSAGING_PATH = var.messaging_path

    # ── Event Grid — endpoint for Critical enquiry alerts ──────────────────
    # The Function App publishes to this topic using managed identity.
    EVENTGRID_TOPIC_ENDPOINT = "https://${azurerm_eventgrid_topic.critical.name}.${var.location}-1.eventgrid.azure.net/api/events"

    # ── Functions host ─────────────────────────────────────────────────────
    # FUNCTIONS_EXTENSION_VERSION and FUNCTIONS_WORKER_RUNTIME are set
    # automatically by the azurerm provider for Linux Function Apps but
    # declared here explicitly for clarity.
    FUNCTIONS_EXTENSION_VERSION = "~4"
    FUNCTIONS_WORKER_RUNTIME    = "python"
  }
}

# ── API Management ────────────────────────────────────────────────────────────
# Developer SKU is cheapest but has no SLA and no production support.
# Upgrade to Basic or Standard before going live.
# APIM takes 30–45 minutes to provision — plan accordingly.

resource "azurerm_api_management" "main" {
  name                = "apim-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  publisher_name      = "Enquiry Hub"
  publisher_email     = var.apim_publisher_email

  sku_name = "Developer_1"

  # System-assigned identity allows APIM to call the Function App backend
  # using managed identity auth in the inbound policy (optional).
  identity {
    type = "SystemAssigned"
  }
}

# ── Event Grid Topic ──────────────────────────────────────────────────────────
# The process_enquiry function publishes a "Critical" event here whenever
# urgency == "Critical". A Logic App subscribes and sends an email alert.

resource "azurerm_eventgrid_topic" "critical" {
  name                = "egt-${var.project_name}-critical-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
}

# Store the Event Grid topic key in Key Vault so the Function App can retrieve
# it at runtime without embedding the secret in app settings.
resource "azurerm_key_vault_secret" "eventgrid_key" {
  name         = "eventgrid-topic-key"
  value        = azurerm_eventgrid_topic.critical.primary_access_key
  key_vault_id = var.keyvault_id

  # Ensure the Function App's RBAC role (Key Vault Secrets User) is assigned
  # before the secret is written; managed by rbac.tf via depends_on.
}

# ── External Entra app registration for SWA built-in authentication ──────────
#
# The app registration and client secret are managed outside Terraform.
# CI passes the client_id, tenant_id, and client_secret via TF_VAR_* values.
#
# After the first SWA deployment, manually add this redirect URI to the app:
#   https://<swa-default-hostname>/.auth/login/aad/callback

# ── Azure Static Web App ───────────────────────────────────────────────────────
# Standard SKU is required for the linked Function App backend feature.
#
# NOTE: Azure Static Web Apps does not yet support australiaeast.
# East Asia is the closest supported region; the static content is served via
# Azure's global CDN regardless of which region the SWA resource is homed in.

resource "azurerm_static_web_app" "main" {
  name                = "swa-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = "eastasia" # Nearest SWA-supported region to Australia East
  sku_tier            = "Standard"
  sku_size            = "Standard"

  # Entra ID auth app settings — read by staticwebapp.config.json at runtime.
  # AZURE_CLIENT_SECRET is injected here (server-side only) and never exposed
  # to browsers or committed to source control.
  app_settings = {
    AZURE_CLIENT_ID     = var.swa_auth_client_id
    AZURE_CLIENT_SECRET = var.swa_auth_client_secret
    AZURE_TENANT_ID     = var.swa_auth_tenant_id
  }
}

# Link the existing Function App as the /api/* backend for SWA.
# The browser calls relative URLs (/api/chat, /api/submit); SWA forwards them
# server-side to the Function App — no API key or token in the browser.
resource "azurerm_static_web_app_function_app_registration" "main" {
  static_web_app_id = azurerm_static_web_app.main.id
  function_app_id   = azurerm_linux_function_app.main.id
}

# ── APIM diagnostic settings ──────────────────────────────────────────────────
# Sends APIM gateway logs and metrics to the shared Log Analytics workspace.
# GatewayLogs populate the ApiManagementGatewayLogs table, which is queried
# by the Sentinel analytics rules in the monitoring module.

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim-${var.project_name}-${var.environment}"
  target_resource_id         = azurerm_api_management.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
