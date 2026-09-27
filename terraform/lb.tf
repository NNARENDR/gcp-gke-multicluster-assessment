# Static global IP for the Multi-cluster Ingress (stable across re-creation)
resource "google_compute_global_address" "mci" {
  name = "mci-global-ip"
}
