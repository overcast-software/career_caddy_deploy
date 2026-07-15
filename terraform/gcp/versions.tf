# Career Caddy on GCP — the reference config the maintainers run in production.
#
# Modern-GCP mapping of the compose stack: Cloud Run services (api/events/
# frontend/mcp/chat + a Cloud Tasks handler) reached on the apex via a Cloud Run
# domain mapping, with the frontend nginx path-routing /api, /api/v1/events and
# /mcp same-origin to the siblings (no load balancer, no CORS). Cloud SQL for
# Postgres, Secret Manager for secrets, Artifact Registry for the images.
#
# Configure a remote backend before applying (see backend.tf.example) — state
# holds generated DB/Django secrets and must never be local or committed.
#
# Works with both Terraform and OpenTofu — the google provider is identical.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
