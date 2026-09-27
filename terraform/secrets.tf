# Secret container only; the value is added via gcloud so it never lands in Terraform state
resource "google_secret_manager_secret" "app_b_api_key" {
  secret_id = "app-b-api-key"
  replication {
    auto {}
  }
}

# Only App B's identity can read this secret (secret-level binding = least privilege)
resource "google_secret_manager_secret_iam_member" "app_b_access" {
  secret_id = google_secret_manager_secret.app_b_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app["app-b"].email}"
}
