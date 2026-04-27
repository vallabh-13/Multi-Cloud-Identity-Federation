# ── AWS Outputs ────────────────────────────────────────────────────────────────

output "aws_cluster_name" {
  description = "EKS cluster name"
  value       = module.aws.cluster_name
}

output "aws_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.aws.cluster_endpoint
}

output "aws_oidc_provider_url" {
  description = "EKS OIDC provider URL (used for Workload Identity and RBAC)"
  value       = module.aws.oidc_provider_url
}

output "aws_kubeconfig_command" {
  description = "Command to update kubeconfig for EKS"
  value       = module.aws.kubeconfig_command
}

# ── Azure Outputs ──────────────────────────────────────────────────────────────

output "azure_cluster_name" {
  description = "AKS cluster name"
  value       = module.azure.cluster_name
}

output "azure_cluster_endpoint" {
  description = "AKS cluster API server endpoint"
  value       = module.azure.cluster_endpoint
  sensitive   = true
}

output "azure_resource_group_name" {
  description = "Azure resource group containing AKS"
  value       = module.azure.resource_group_name
}

output "azure_kubeconfig_command" {
  description = "Command to update kubeconfig for AKS"
  value       = module.azure.kubeconfig_command
}

# ── GCP Outputs ────────────────────────────────────────────────────────────────

output "gcp_cluster_name" {
  description = "GKE cluster name"
  value       = module.gcp.cluster_name
}

output "gcp_cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = module.gcp.cluster_endpoint
  sensitive   = true
}

output "gcp_workload_identity_pool" {
  description = "GCP Workload Identity Pool resource name for Entra ID federation"
  value       = module.gcp.workload_identity_pool
}

output "gcp_kubeconfig_command" {
  description = "Command to update kubeconfig for GKE"
  value       = module.gcp.kubeconfig_command
}
