output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "cluster_endpoint" {
  description = "AKS cluster API server endpoint"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "resource_group_name" {
  description = "Azure resource group name containing AKS"
  value       = azurerm_resource_group.main.name
}

output "kubeconfig_command" {
  description = "Azure CLI command to update local kubeconfig for kubectl access"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}
