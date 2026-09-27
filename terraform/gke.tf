locals {
  clusters = {
    primary = {
      name        = "gke-primary"
      region      = var.primary_region
      zone        = "${var.primary_region}-a"
      subnet      = google_compute_subnetwork.gke_primary.name
      master_cidr = "172.16.0.0/28"
    }
    secondary = {
      name        = "gke-secondary"
      region      = var.secondary_region
      zone        = "${var.secondary_region}-b"
      subnet      = google_compute_subnetwork.gke_secondary.name
      master_cidr = "172.16.0.16/28"
    }
  }
}

# ---------------- Clusters ----------------
resource "google_container_cluster" "this" {
  for_each = local.clusters

  name           = each.value.name
  location       = each.value.region # regional control plane
  node_locations = [each.value.zone] # nodes in 1 zone (quota/cost)

  network    = google_compute_network.vpc.id
  subnetwork = each.value.subnet

  # We manage our own node pool below
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false
  release_channel { channel = "REGULAR" }

  # VPC-native: use the secondary ranges from network.tf
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes, public control-plane endpoint (for kubectl from Cloud Shell)
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = each.value.master_cidr
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus { enabled = true }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Register to the fleet (needed for Multi-cluster Ingress)
  fleet {
    project = var.project_id
  }
}

# ---------------- Node pools ----------------
resource "google_container_node_pool" "general" {
  for_each = local.clusters

  name     = "general-pool"
  cluster  = google_container_cluster.this[each.key].id
  location = each.value.region

  initial_node_count = 1
  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = "e2-standard-2"
    disk_type       = "pd-standard"
    disk_size_gb    = 50
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }

    labels = {
      pool = "general"
    }
  }
}
