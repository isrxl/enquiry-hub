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

variable "alert_email" {
  type        = string
  description = "Email address for Azure Monitor alert notifications."
}
