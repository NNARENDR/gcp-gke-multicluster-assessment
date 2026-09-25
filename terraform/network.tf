# ---------------- VPC ----------------
resource "google_compute_network" "vpc" {
  name                    = "gke-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

# ---------------- Subnets ----------------
resource "google_compute_subnetwork" "gke_primary" {
  name                     = "gke-primary-subnet"
  region                   = var.primary_region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

resource "google_compute_subnetwork" "gke_secondary" {
  name                     = "gke-secondary-subnet"
  region                   = var.secondary_region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.11.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.21.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.31.0.0/20"
  }
}

resource "google_compute_subnetwork" "ops" {
  name                     = "ops-subnet"
  region                   = var.primary_region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.12.0.0/24"
  private_ip_google_access = true
}

# ---------------- Cloud Router + NAT (per region) ----------------
resource "google_compute_router" "primary" {
  name    = "router-${var.primary_region}"
  region  = var.primary_region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "primary" {
  name                               = "nat-${var.primary_region}"
  router                             = google_compute_router.primary.name
  region                             = var.primary_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router" "secondary" {
  name    = "router-${var.secondary_region}"
  region  = var.secondary_region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "secondary" {
  name                               = "nat-${var.secondary_region}"
  router                             = google_compute_router.secondary.name
  region                             = var.secondary_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------- Firewall rules ----------------
# Internal traffic inside the VPC (nodes, pods, services)
resource "google_compute_firewall" "allow_internal" {
  name          = "allow-internal"
  network       = google_compute_network.vpc.id
  source_ranges = ["10.0.0.0/8"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# Google Load Balancer health checks (fixed Google ranges)
resource "google_compute_firewall" "allow_health_checks" {
  name          = "allow-lb-health-checks"
  network       = google_compute_network.vpc.id
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]

  allow { protocol = "tcp" }
}

# SSH only through Identity-Aware Proxy (no public SSH)
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "allow-iap-ssh"
  network       = google_compute_network.vpc.id
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------------- Private Service Access ----------------
resource "google_compute_global_address" "psa_range" {
  name          = "psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
  deletion_policy         = "ABANDON"
}
