# ─────────────────────────────────────────────────────────────────────────────
# AI module — Azure OpenAI
#
# Provisions:
#   • Cognitive Services account  (kind = OpenAI, sku = S0)
#   • Model deployment            (GlobalStandard, capacity = 10 PTUs)
#   • Private endpoint + private DNS zone + VNET link
#
# NOTE: Azure OpenAI availability varies by region. australiaeast supports
# GPT-4o as of early 2025 — verify at aka.ms/aoai-model-matrix before deploy.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_cognitive_account" "openai" {
  name                = "oai-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  kind                = "OpenAI"
  sku_name            = "S0"

  # Disable public access — the Function App reaches OpenAI via private endpoint.
  public_network_access_enabled = false

  # Required to allow the managed identity RBAC assignment in compute/rbac.tf
  # to propagate before the Function App starts calling the endpoint.
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.openai_model
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.openai_model
    version = "2024-11-20" # Pin to a stable version; update when a newer GA version is available
  }

  # GlobalStandard: Microsoft manages capacity across regions for best availability.
  # capacity = 10 PTUs (provisioned throughput units) — sufficient for dev workloads.
  scale {
    type     = "GlobalStandard"
    capacity = 10
  }
}

# ── Private endpoint ──────────────────────────────────────────────────────────

resource "azurerm_private_endpoint" "openai" {
  name                = "pe-oai-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-openai"
    private_connection_resource_id = azurerm_cognitive_account.openai.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnsz-openai"
    private_dns_zone_ids = [azurerm_private_dns_zone.openai.id]
  }
}

resource "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "openai" {
  name                  = "pdnslink-openai"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.openai.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}
