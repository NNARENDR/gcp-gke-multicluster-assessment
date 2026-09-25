# gcp-gke-multicluster-assessment
GCP Assement
Project name -GKE Assessment
Project number- 633465245867
Project ID- gke-assessment

2. gcloud config set project 633465245867
gcloud billing projects describe 633465245867


 GCP Multi-Cluster GKE Assessment

End-to-end setup of a GCP project with two GKE clusters (us-central1 and us-east1),
two stateless web applications, global load balancing, and full observability
(Cloud Logging → BigQuery → Grafana), built with Terraform.

## Table of Contents
1. Project Setup
2. Networking (VPC, Subnets, Cloud NAT, Firewall)
3. IAM
4. GKE Clusters
5. Application Deployment
6. Global Load Balancing
7. Observability (Logging, BigQuery, Grafana)
8. Security
9. Troubleshooting
10. Design Decisions
11. Cleanup

---

## 1. Project Setup

### Resource hierarchy
| Level        | Value |
|--------------|-------|
| Organization | None (personal account) |
| Folder       | None (folders require an Organization) |
| Project name | GKE Assessment |
| Project ID   | gke-assessment |

**Target enterprise hierarchy:**
`Organization → Folder (Prod) → Folder (Apps) → Project (gke-assessment)`

> Folders need an Organization node (Cloud Identity / Workspace with a verified domain).
> A personal account has no Organization, so the project was created without a parent.
> In an enterprise, the project would be created by Terraform (`google_project` with
> `folder_id`) through a landing-zone / project-factory pipeline, and org policies and
> IAM would be applied at folder level and inherited by the project.

### Ways to create a project
| Method        | Example | When to use |
|---------------|---------|-------------|
| Console       | IAM & Admin → Create Project | Learning, one-off |
| gcloud CLI    | `gcloud projects create gke-assessment` | Scripts |
| Terraform     | `google_project` resource | Enterprise standard (repeatable, reviewed in Git) |

This project was created via the Console. All resources **inside** the project are created with Terraform.


one-time setup commands: set project, enable APIs, create the state bucket
Terraform commands: init, plan, apply, destroy
gcloud container clusters get-credentials (to connect kubectl to the clusters)
kubectl apply commands for deploying the apps
verification commands, like kubectl get pods and curl <LB-IP>

Leave out:

### Steps
```bash
# Set the active project in Cloud Shell
gcloud config set project gke-assessment

# Verify billing is linked
gcloud billing projects describe gke-assessment
# Expected: billingEnabled: true
```

### Cost control
- Free-trial billing account ($300 credit).
- Budget alert at $50 (50% / 90% / 100% thresholds).
- Infrastructure is destroyed with `terraform destroy` when not in use and recreated with `terraform apply`

2.### Enable required APIs
```bash
-->gcloud services enable compute.googleapis.com container.googleapis.com \
  servicenetworking.googleapis.com artifactregistry.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com bigquery.googleapis.com \
  dns.googleapis.com secretmanager.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com gkehub.googleapis.com \
  multiclusterservicediscovery.googleapis.com multiclusteringress.googleapis.com \
  trafficdirector.googleapis.com cloudtrace.googleapis.com

-->verify -gcloud services list --enabled

API	Used for
compute	VPC, subnets, NAT, firewall, load balancer
container	GKE clusters
servicenetworking	Private Service Access
artifactregistry	Storing Docker images
logging / monitoring	Cloud Logging, Cloud Monitoring
bigquery	Log analysis for Grafana
dns	Cloud DNS
secretmanager	Storing secrets
iam / cloudresourcemanager	Service accounts, roles, project management
gkehub / multicluster* / trafficdirector	Fleet and multi-cluster ingress across both clusters
cloudtrace	Distributed tracing


3. ### Terraform remote state
Terraform state is stored in a GCS bucket with versioning enabled.
- **Why remote:** shared across the team, safe from local loss, and locked during runs to prevent corruption.
- **Why versioning:** allows recovery of a previous state if it gets corrupted.

```bash
gcloud storage buckets create gs://gke-assessment-tfstate \
  --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://gke-assessment-tfstate --versioning

## 3.1 Terraform Setup

### Prerequisites
- Google Cloud SDK (`gcloud`), Terraform >= 1.5, `kubectl` (Cloud Shell used for this project)
- Terraform is not preinstalled in Cloud Shell; install it from the HashiCorp apt repo:
  https://developer.hashicorp.com/terraform/install

### Files
| File | Purpose |
|---|---|
| `versions.tf` | Terraform/provider versions and GCS remote backend |
| `provider.tf` | Google provider (project, region) |
| `variables.tf` | Input variables (project ID, regions) |
| `terraform.tfvars.example` | Sample values; copy to `terraform.tfvars` |
| `network.tf` | VPC, subnets, Cloud Router, Cloud NAT, firewall, Private Service Access |
| `outputs.tf` | Output values |
| `.terraform.lock.hcl` | Pins the provider version (committed) |

### Remote state
State is stored in the GCS bucket `gke-assessment-tfstate` (versioning enabled, native locking).
The bucket is created once with `gcloud` before Terraform runs, because the backend must exist before `terraform init`.

### Run
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Drift check: `terraform plan -refresh-only`

## 4. Networking
| Subnet | Region | Nodes | Pods | Services |
|---|---|---|---|---|
| gke-primary-subnet | us-central1 | 10.10.0.0/20 | 10.20.0.0/16 | 10.30.0.0/20 |
| gke-secondary-subnet | us-east1 | 10.11.0.0/20 | 10.21.0.0/16 | 10.31.0.0/20 |
| ops-subnet | us-central1 | 10.12.0.0/24 | – | – |

- Custom-mode VPC `gke-vpc` with VPC-native (alias IP) ranges for pods and services
- Cloud Router + Cloud NAT per region: outbound internet for private nodes, no inbound exposure
- Firewall: internal traffic, Google LB health-check ranges (`35.191.0.0/16`, `130.211.0.0/22`), IAP-only SSH
- Private Service Access for Google managed services (Cloud SQL, Memorystore)

```


