output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "gke_primary_subnet" {
  value = google_compute_subnetwork.gke_primary.name
}

output "gke_secondary_subnet" {
  value = google_compute_subnetwork.gke_secondary.name
}
