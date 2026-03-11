variable "project_name" {
  type        = string
  description = "Short name prefix for all resources."
}

variable "environment" {
  type        = string
  description = "Deployment environment label (dev / staging / prod)."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy into."
}
