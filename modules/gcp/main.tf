# ── GCP Module: VPC + Private GKE Cluster with Workload Identity ───────────────
# Creates a private GKE cluster and a Workload Identity Pool with an OIDC
# provider pointing to Entra ID, so Entra ID tokens can be exchanged for
# short-lived GCP credentials without storing service account keys.

locals {
  name_prefix    = "${var.project_name}-${var.environment}"
  subnet_cidr    = "10.40.0.0/24"
  pods_range     = "10.41.0.0/16"
  services_range = "10.42.0.0/16"

  # GCP labels must be lowercase
  labels = {
    project     = "hybrid-cloud-identity"
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ── VPC Network (custom mode — no auto-created subnets) ───────────────────────

resource "google_compute_network" "main" {
  name                    = "${local.name_prefix}-vpc"
  auto_create_subnetworks = false
  project                 = var.gcp_project_id
}

resource "google_compute_subnetwork" "main" {
  name          = "${local.name_prefix}-subnet"
  ip_cidr_range = local.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.main.id
  project       = var.gcp_project_id

  # Secondary ranges required for VPC-native GKE (alias IP)
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.pods_range
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.services_range
  }

  private_ip_google_access = true
}

# ── Cloud Router + NAT (private nodes need outbound internet for image pulls) ──

resource "google_compute_router" "main" {
  name    = "${local.name_prefix}-router"
  region  = var.gcp_region
  network = google_compute_network.main.id
  project = var.gcp_project_id
}

resource "google_compute_router_nat" "main" {
  name                               = "${local.name_prefix}-nat"
  router                             = google_compute_router.main.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  project                            = var.gcp_project_id
}

# ── Firewall: allow internal traffic only ─────────────────────────────────────

resource "google_compute_firewall" "internal" {
  name    = "${local.name_prefix}-allow-internal"
  network = google_compute_network.main.id
  project = var.gcp_project_id

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }

  source_ranges = [local.subnet_cidr, local.pods_range, local.services_range]
  description   = "Allow internal traffic between nodes, pods, and services"
}

# ── GKE Private Cluster ────────────────────────────────────────────────────────

resource "google_container_cluster" "main" {
  name     = "${local.name_prefix}-gke"
  location = var.gcp_region
  project  = var.gcp_project_id

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  # Remove default node pool so we can configure our own below
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity: K8s service accounts can impersonate GCP service accounts
  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  # VPC-native networking required for private cluster and Workload Identity
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.32/28"
  }

  release_channel {
    channel = "STABLE"
  }

  resource_labels = local.labels
}

# ── GKE Node Pool ──────────────────────────────────────────────────────────────

resource "google_container_node_pool" "main" {
  name     = "${local.name_prefix}-nodes"
  location = var.gcp_region
  cluster  = google_container_cluster.main.name
  project  = var.gcp_project_id

  initial_node_count = 2

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-medium"
    disk_type    = "pd-standard"
    disk_size_gb = 50

    # GKE_METADATA mode routes metadata server requests through Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels       = local.labels
  }
}

# ── Workload Identity Federation: Entra ID OIDC Pool ──────────────────────────
# Allows Entra ID JWT tokens to be exchanged for short-lived GCP credentials.
# No service account keys are ever stored — tokens are validated against
# Entra ID's OIDC discovery endpoint and bound to our specific tenant.

resource "google_iam_workload_identity_pool" "entra" {
  workload_identity_pool_id = "${local.name_prefix}-pool"
  display_name              = "Entra ID Federation Pool"
  description               = "Workload Identity Pool for Microsoft Entra ID OIDC federation"
  project                   = var.gcp_project_id
}

resource "google_iam_workload_identity_pool_provider" "entra_oidc" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.entra.workload_identity_pool_id
  workload_identity_pool_provider_id = "${local.name_prefix}-oidc"
  display_name                       = "Entra ID OIDC Provider"
  project                            = var.gcp_project_id

  # Map Entra ID JWT claims to GCP principal attributes for IAM bindings
  attribute_mapping = {
    "google.subject"   = "assertion.sub"
    "attribute.tenant" = "assertion.tid"
    "attribute.upn"    = "assertion.upn"
    "attribute.groups" = "assertion.groups"
  }

  # Restrict token acceptance to our specific Entra ID tenant
  attribute_condition = "assertion.tid == \"${var.entra_tenant_id}\""

  oidc {
    issuer_uri = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0"
  }
}

# ── MANUAL STEPS: Completing Entra ID → GKE RBAC ─────────────────────────────
# The Workload Identity Pool above bridges Entra ID tokens to GCP principals.
# To complete the integration:
#
# 1. Register an App in Entra ID (App Registrations → New registration):
#    - Set audience to: api://AzureADTokenExchange
#    - Note the Application (client) ID
#
# 2. To grant GCP IAM roles to Entra ID users/groups, use principal sets:
#    gcloud projects add-iam-policy-binding PROJECT_ID \
#      --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/attribute.upn/user@domain.com" \
#      --role="roles/container.developer"
#
# 3. For kubectl access, configure the credential helper in kubeconfig to
#    use the gke-gcloud-auth-plugin with Workload Identity Federation tokens.
#
# 4. Apply k8s/rbac.yaml with Entra ID group object IDs substituted into
#    the ClusterRoleBinding subjects.
