# ---------- BigQuery dataset for exported logs ----------
resource "google_bigquery_dataset" "logs" {
  dataset_id                      = "gke_logs"
  location                        = "US"
  description                     = "Exported LB and GKE logs for analysis and Grafana"
  default_partition_expiration_ms = 2592000000 # 30 days, cost control
  delete_contents_on_destroy      = true
}

# ---------- Sink 1: Load balancer request logs ----------
resource "google_logging_project_sink" "lb" {
  name                   = "lb-requests-to-bq"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs.dataset_id}"
  filter                 = "resource.type=\"http_load_balancer\""
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

# ---------- Sink 2: GKE application + cluster logs ----------
resource "google_logging_project_sink" "gke" {
  name                   = "gke-logs-to-bq"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs.dataset_id}"
  filter                 = "resource.type=(\"k8s_container\" OR \"k8s_pod\" OR \"k8s_node\" OR \"k8s_cluster\")"
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

# ---------- Let each sink write into the dataset ----------
resource "google_bigquery_dataset_iam_member" "lb_sink_writer" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.lb.writer_identity
}

resource "google_bigquery_dataset_iam_member" "gke_sink_writer" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.gke.writer_identity
}
