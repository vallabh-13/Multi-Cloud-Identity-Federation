variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
}

variable "entra_tenant_id" {
  description = "Microsoft Entra ID tenant ID for Workload Identity Federation"
  type        = string
  sensitive   = true
}

variable "entra_domain" {
  description = "Microsoft Entra ID domain (e.g. corp.onmicrosoft.com)"
  type        = string
}

variable "labels" {
  description = "Common labels to apply to all GCP resources"
  type        = map(string)
}
