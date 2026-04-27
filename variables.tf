variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "hybrid-cloud-identity"
}

variable "environment" {
  description = "Environment label (e.g. lab, dev, prod)"
  type        = string
  default     = "lab"
}

variable "entra_tenant_id" {
  description = "Microsoft Entra ID (Azure AD) tenant ID"
  type        = string
  sensitive   = true
}

variable "entra_domain" {
  description = "Microsoft Entra ID domain (e.g. corp.onmicrosoft.com)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "azure_region" {
  description = "Azure region for AKS cluster"
  type        = string
  default     = "East US"
}

variable "azure_resource_group_name" {
  description = "Azure resource group name for AKS resources"
  type        = string
  default     = "hybrid-cloud-identity-rg"
}

variable "gcp_project_id" {
  description = "GCP project ID for GKE cluster"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for GKE cluster"
  type        = string
  default     = "us-central1"
}
