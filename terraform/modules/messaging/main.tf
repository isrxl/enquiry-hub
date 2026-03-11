# ─────────────────────────────────────────────────────────────────────────────
# Messaging module
#
# Supports three paths controlled by var.messaging_path:
#
#   Path A — standard:
#     Service Bus Standard SKU + queue. No private endpoint (Standard does
#     not support them). Cheapest option, suitable for dev/test.
#
#   Path B — premium:
#     Service Bus Premium SKU + queue + private endpoint + private DNS zone.
#     Required for fully private network topology.
#
#   Path C — storagequeue:
#     Azure Storage Account + queue + private endpoint + private DNS zone.
#     Lowest-cost private option; trigger support via WebJobs SDK.
#
# The `count` meta-argument activates/deactivates resources per path.
# Outputs are nullable — compute module must handle null values.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  is_sb_standard  = var.messaging_path == "standard"
  is_sb_premium   = var.messaging_path == "premium"
  is_storage_queue = var.messaging_path == "storagequeue"

  # True for both Service Bus paths (A and B)
  is_service_bus = local.is_sb_standard || local.is_sb_premium
}

# ── Path A & B: Service Bus namespace ────────────────────────────────────────

resource "azurerm_servicebus_namespace" "main" {
  count = local.is_service_bus ? 1 : 0

  name                = "sb-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Standard SKU for path A; Premium required for path B (private endpoints)
  sku = local.is_sb_premium ? "Premium" : "Standard"
}

resource "azurerm_servicebus_queue" "enquiry" {
  count = local.is_service_bus ? 1 : 0

  name         = "enquiry-queue"
  namespace_id = azurerm_servicebus_namespace.main[0].id

  # Dead-letter queue retains poison messages for inspection / replay
  dead_lettering_on_message_expiration = true
}

# ── Path B only: private endpoint for Service Bus ────────────────────────────

resource "azurerm_private_endpoint" "servicebus" {
  count = local.is_sb_premium ? 1 : 0

  name                = "pe-sb-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-servicebus"
    private_connection_resource_id = azurerm_servicebus_namespace.main[0].id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnsz-servicebus"
    private_dns_zone_ids = [azurerm_private_dns_zone.servicebus[0].id]
  }
}

resource "azurerm_private_dns_zone" "servicebus" {
  count = local.is_sb_premium ? 1 : 0

  name                = "privatelink.servicebus.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus" {
  count = local.is_sb_premium ? 1 : 0

  name                  = "pdnslink-servicebus"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

# ── Path C: Storage Account + queue ──────────────────────────────────────────

resource "azurerm_storage_account" "queue" {
  count = local.is_storage_queue ? 1 : 0

  name                     = "stq${replace(var.project_name, "-", "")}${var.environment}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Disable public blob access; all access via private endpoint
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_queue" "enquiry" {
  count = local.is_storage_queue ? 1 : 0

  name                 = "enquiry-queue"
  storage_account_name = azurerm_storage_account.queue[0].name
}

# ── Path C only: private endpoint for Storage Queue ──────────────────────────

resource "azurerm_private_endpoint" "storagequeue" {
  count = local.is_storage_queue ? 1 : 0

  name                = "pe-stq-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "psc-storagequeue"
    private_connection_resource_id = azurerm_storage_account.queue[0].id
    # "queue" subresource targets the Queue service endpoint specifically
    subresource_names              = ["queue"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnsz-storagequeue"
    private_dns_zone_ids = [azurerm_private_dns_zone.storagequeue[0].id]
  }
}

resource "azurerm_private_dns_zone" "storagequeue" {
  count = local.is_storage_queue ? 1 : 0

  name                = "privatelink.queue.core.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storagequeue" {
  count = local.is_storage_queue ? 1 : 0

  name                  = "pdnslink-storagequeue"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.storagequeue[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}
