# Hybrid Cloud Identity Federation — Root Module
# Orchestrates AWS EKS, Azure AKS, and GCP GKE clusters connected via Entra ID.
# Users synced from on-prem AD to Entra ID authenticate into all three clusters
# using their Entra ID identity, with RBAC enforced from AD group membership.

locals {
  common_tags = {
    Project     = "hybrid-cloud-identity"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "aws" {
  source = "./modules/aws"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  tags         = local.common_tags
}

module "azure" {
  source = "./modules/azure"

  project_name              = var.project_name
  environment               = var.environment
  azure_region              = var.azure_region
  azure_resource_group_name = var.azure_resource_group_name
  entra_tenant_id           = var.entra_tenant_id
  tags                      = local.common_tags
}

module "gcp" {
  source = "./modules/gcp"

  project_name    = var.project_name
  environment     = var.environment
  gcp_project_id  = var.gcp_project_id
  gcp_region      = var.gcp_region
  entra_tenant_id = var.entra_tenant_id
  entra_domain    = var.entra_domain
  labels          = local.common_tags
}
