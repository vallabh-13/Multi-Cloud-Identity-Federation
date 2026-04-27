# ── Azure Module: VNet + AKS with Native Entra ID Integration ─────────────────
# AKS has first-class Entra ID (Azure AD) RBAC support — the simplest of the
# three clouds. Enabling the azure_active_directory_role_based_access_control
# block with managed = true means AKS handles OIDC validation automatically.
# Users synced from on-prem AD via Entra Connect are immediately recognized.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  vnet_cidr   = "10.30.0.0/16"
  aks_subnet  = "10.30.1.0/24"
}

# ── Resource Group ─────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.azure_resource_group_name
  location = var.azure_region
  tags     = var.tags
}

# ── Virtual Network ────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "${local.name_prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [local.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${local.name_prefix}-aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.aks_subnet]
}

# ── AKS Cluster with Entra ID RBAC ────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "main" {
  name                = "${local.name_prefix}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${local.name_prefix}-aks"
  kubernetes_version  = "1.35"

  # System-assigned managed identity — no service principal credentials needed
  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                = "default"
    vm_size             = "Standard_D2s_v3"
    vnet_subnet_id      = azurerm_subnet.aks.id
    enable_auto_scaling = true
    node_count          = 2
    min_count           = 1
    max_count           = 3
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  # Native Entra ID RBAC — users and groups from AD are recognized automatically.
  # azure_rbac_enabled = true means Azure RBAC controls K8s access (not just kubeconfig auth).
  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
    tenant_id          = var.entra_tenant_id
  }

  tags = var.tags
}
