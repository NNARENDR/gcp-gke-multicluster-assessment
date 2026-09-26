# ============ 1. GKE node service account (shared by all node pools) ============
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE node pools"
}

locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/autoscaling.metricsWriter",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset(local.gke_node_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ============ 2. App service accounts (one per app, Workload Identity) ============
locals {
  apps = {
    app-a = ["roles/cloudtrace.agent", "roles/monitoring.metricWriter"]
    app-b = ["roles/cloudtrace.agent", "roles/monitoring.metricWriter"]
  }

  app_role_bindings = {
    for b in flatten([
      for app, roles in local.apps : [
        for role in roles : { key = "${app}-${role}", app = app, role = role }
      ]
    ]) : b.key => b
  }
}

resource "google_service_account" "app" {
  for_each     = local.apps
  account_id   = "${each.key}-sa"
  display_name = "Workload Identity SA for ${each.key}"
}

resource "google_project_iam_member" "app" {
  for_each = local.app_role_bindings
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.app[each.value.app].email}"
}

# ============ 3. CI/CD service account ============
resource "google_service_account" "cicd" {
  account_id   = "cicd-sa"
  display_name = "CI/CD pipeline"
}

locals {
  cicd_roles = [
    "roles/artifactregistry.writer",
    "roles/container.developer",
  ]
}

resource "google_project_iam_member" "cicd" {
  for_each = toset(local.cicd_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.cicd.email}"
}

# ============ 4. Human teams (optional, set team_members in tfvars) ============
locals {
  team_roles = {
    dev = ["roles/container.developer", "roles/logging.viewer"]
    ops = ["roles/container.admin", "roles/compute.networkViewer", "roles/monitoring.editor"]
    sre = ["roles/monitoring.editor", "roles/logging.viewer", "roles/container.viewer", "roles/bigquery.dataViewer"]
  }

  team_bindings = {
    for b in flatten([
      for team, roles in local.team_roles : [
        for role in roles : { key = "${team}-${role}", team = team, role = role }
      ]
    ]) : b.key => b if lookup(var.team_members, b.team, "") != ""
  }
}

resource "google_project_iam_member" "teams" {
  for_each = local.team_bindings
  project  = var.project_id
  role     = each.value.role
  member   = var.team_members[each.value.team]
}
