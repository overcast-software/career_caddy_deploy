# Artifact Registry — Cloud Run pulls images from here. The public GHCR images
# must be mirrored in (see README): one repo holds all three images.

resource "google_artifact_registry_repository" "main" {
  location      = var.ar_region
  repository_id = "career-caddy"
  format        = "DOCKER"
  description   = "Mirror of the public GHCR Career Caddy images for Cloud Run."
  labels        = local.common_labels

  depends_on = [google_project_service.apis]
}
