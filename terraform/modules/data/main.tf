# ─────────────────────────────────────────────────────────────────────────────
# Data module — Cosmos DB (NoSQL / Serverless)
#
# Provisions:
#   • Cosmos DB account  (Serverless, Session consistency, GlobalDocumentDB)
#   • SQL database       "EnquiryHub"
#   • SQL container      "Enquiries"  (partition key: /dateKey)
#   • Private endpoint + private DNS zone + VNET link
#
# Partition key /dateKey (YYYY-MM-DD) keeps hot partitions bounded and lets
# the chat function efficiently query recent enquiries by date range.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # GlobalDocumentDB = Core (SQL) API; the only API that supports
  # the azurerm_cosmosdb_sql_* child resources below.
  offer_type = "Standard"
  kind       = "GlobalDocumentDB"

  # Serverless billing: no provisioned RU/s, pay only for consumed RUs.
  # Ideal for dev workloads and spiky production traffic.
  capabilities {
    name = "EnableServerless"
  }

  # Session consistency: strongest level compatible with serverless;
  # guarantees reads reflect writes from the same session token.
  consistency_policy {
    consistency_level = "Session"
  }

  # Single-region write location; no geo-redundancy in dev.
  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # Disable public network access — all access goes through the private endpoint.
  public_network_access_enabled = false
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "EnquiryHub"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "enquiries" {
  name                = "Enquiries"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name

  # Partition key distributes data evenly across logical partitions by date.
  partition_key_paths   = ["/dateKey"]
  partition_key_version = 1

  # TTL of 30 days (2 592 000 seconds) — appropriate for non-prod/test where
  # data does not need long-term retention. Set to -1 to disable TTL in prod,
  # then apply a separate data lifecycle / purge policy aligned to your
  # PII retention obligations.
  default_ttl = 2592000
}

# ── Private endpoint ──────────────────────────────────────────────────────────

resource "azurerm_private_endpoint" "cosmos" {
  name                = "pe-cosmos-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-cosmos"
    private_connection_resource_id = azurerm_cosmosdb_account.main.id
    # "Sql" subresource targets the Core (SQL) API endpoint
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnsz-cosmos"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos.id]
  }
}

resource "azurerm_private_dns_zone" "cosmos" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  name                  = "pdnslink-cosmos"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cosmos.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}
