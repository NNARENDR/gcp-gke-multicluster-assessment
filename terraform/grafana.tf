# Read-only identity for Grafana Cloud
resource "google_service_account" "grafana" {
  account_id   = "grafana-sa"
  display_name = "Grafana Cloud (read-only)"
}

# Run BigQuery query jobs
resource "google_project_iam_member" "grafana_bq_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grafana.email}"
}

# Read ONLY the gke_logs dataset
resource "google_bigquery_dataset_iam_member" "grafana_bq_read" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grafana.email}"
}

# Read Cloud Monitoring metrics (CPU/memory panel)
resource "google_project_iam_member" "grafana_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana.email}"
}
