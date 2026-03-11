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

variable "vnet_id" {
  type        = string
  description = "VNET ID for the private DNS zone VNET link."
}

variable "pe_subnet_id" {
  type        = string
  description = "Subnet ID for the Cosmos DB private endpoint NIC."
}
