data "google_project" "this" {
  project_id = var.project_id
}

# ---------- Multi-cluster Services (service discovery across clusters) ----------
resource "google_gke_hub_feature" "mcs" {
  name     = "multiclusterservicediscovery"
  location = "global"

  depends_on = [google_container_cluster.this]
}

# MCS importer (runs in each cluster) needs to read network info
resource "google_project_iam_member" "mcs_importer" {
  project = var.project_id
  role    = "roles/compute.networkViewer"
  member  = "serviceAccount:${var.project_id}.svc.id.goog[gke-mcs/gke-mcs-importer]"

  depends_on = [google_gke_hub_feature.mcs]
}

# ---------- Multi-cluster Ingress (one global LB for both clusters) ----------
resource "google_gke_hub_feature" "mci" {
  name     = "multiclusteringress"
  location = "global"

  spec {
    multiclusteringress {
      # Config cluster: where MultiClusterIngress/MultiClusterService YAML is applied
      config_membership = "projects/${var.project_id}/locations/${var.primary_region}/memberships/${google_container_cluster.this["primary"].name}"
    }
  }

  depends_on = [google_gke_hub_feature.mcs]
}

# MCI service agent manages load balancer resources on our behalf
resource "google_project_iam_member" "mci_agent" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-multiclusteringress.iam.gserviceaccount.com"

  depends_on = [google_gke_hub_feature.mci]
}
