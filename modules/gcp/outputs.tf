output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "workload_identity_pool" {
  description = "GCP Workload Identity Pool resource name for Entra ID federation"
  value       = google_iam_workload_identity_pool.entra.name
}

output "kubeconfig_command" {
  description = "gcloud command to update local kubeconfig for kubectl access"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.gcp_region} --project ${var.gcp_project_id}"
}
