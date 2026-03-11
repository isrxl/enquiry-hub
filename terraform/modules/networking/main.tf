# ─────────────────────────────────────────────────────────────────────────────
# Networking module
#
# Provisions a single VNET (10.0.0.0/16) with three subnets:
#   snet-apim              – API Management (10.0.1.0/24)
#   snet-functions         – Function App VNET integration (10.0.2.0/24)
#   snet-private-endpoints – Private endpoints for all PaaS services (10.0.3.0/24)
#
# All other modules consume the subnet IDs exposed by this module's outputs.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
}

# Subnet for API Management (must be dedicated; no other resources placed here)
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Subnet for Azure Functions VNET integration.
# Delegation to Microsoft.Web/serverFarms is required for consumption-plan
# Functions to route outbound traffic through the VNET.
resource "azurerm_subnet" "functions" {
  name                 = "snet-functions"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "delegation-functions"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Subnet for private endpoints.
# private_endpoint_network_policies = "Disabled" is required so that the
# network stack does not enforce NSG/UDR rules on private endpoint NICs.
resource "azurerm_subnet" "private_endpoints" {
  name                                          = "snet-private-endpoints"
  resource_group_name                           = var.resource_group_name
  virtual_network_name                          = azurerm_virtual_network.main.name
  address_prefixes                              = ["10.0.3.0/24"]
  private_endpoint_network_policies             = "Disabled"
}

# ── NSG: private-endpoints subnet ─────────────────────────────────────────────
# NOTE: With private_endpoint_network_policies = "Disabled", Azure does not
# enforce NSG inbound rules on private endpoint NICs themselves. The NSG still
# applies to any non-PE resources placed in this subnet and enforces outbound
# rules, providing defence-in-depth and an audit record of allowed flows.

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-pe-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Allow inbound from Functions subnet — Function App calls private endpoints
  # for Cosmos DB, Service Bus (premium), and OpenAI.
  security_rule {
    name                       = "allow-inbound-functions"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.2.0/24"
    destination_address_prefix = "*"
  }

  # Allow inbound from APIM subnet on HTTPS — APIM may call private services
  # directly if APIM policies are later configured to do so.
  security_rule {
    name                       = "allow-inbound-apim"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }

  # Deny all other inbound traffic to the PE subnet.
  security_rule {
    name                       = "deny-other-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}
