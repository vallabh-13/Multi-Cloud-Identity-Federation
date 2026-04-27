variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "azure_region" {
  description = "Azure region"
  type        = string
}

variable "azure_resource_group_name" {
  description = "Azure resource group name"
  type        = string
}

variable "entra_tenant_id" {
  description = "Microsoft Entra ID tenant ID for AKS AAD integration"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
