output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "gke_primary_subnet" {
  value = google_compute_subnetwork.gke_primary.name
}

output "gke_secondary_subnet" {
  value = google_compute_subnetwork.gke_secondary.name
}

output "gke_nodes_sa_email" {
  value = google_service_account.gke_nodes.email
}

output "app_sa_emails" {
  value = { for k, sa in google_service_account.app : k => sa.email }
}

output "cicd_sa_email" {
  value = google_service_account.cicd.email
}
