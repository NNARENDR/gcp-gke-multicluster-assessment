resource "google_artifact_registry_repository" "apps" {
  location      = "us"
  repository_id = "apps"
  format        = "DOCKER"
  description   = "Container images for App A and App B"
}
