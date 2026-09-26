variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "primary_region" {
  description = "Region for primary GKE cluster"
  type        = string
  default     = "us-central1"
}

variable "secondary_region" {
  description = "Region for secondary GKE cluster"
  type        = string
  default     = "us-east1"
}

variable "team_members" {
  description = "Optional IAM member per team, e.g. { dev = \"group:dev-team@googlegroups.com\" }"
  type        = map(string)
  default     = {}
}
