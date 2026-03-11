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

variable "messaging_path" {
  type        = string
  description = "Which messaging backend to provision: standard | premium | storagequeue."
}

variable "vnet_id" {
  type        = string
  description = "VNET ID used for private DNS zone VNET links (paths B and C only)."
}

variable "pe_subnet_id" {
  type        = string
  description = "Subnet ID for private endpoint NICs (paths B and C only)."
}
