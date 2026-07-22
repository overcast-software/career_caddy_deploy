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

# Resolve each service image's tag (var.image_tag, default "latest") to its
# immutable DIGEST at plan time. local.images deploys the digest-pinned ref, which
# is what makes the plain "docker push :latest + tofu apply" workflow actually
# ROLL a new revision: moving the :latest tag changes the resolved digest -> the
# Cloud Run service spec changes -> a new revision deploys. When :latest has NOT
# moved, the digest is identical -> no diff, no needless roll. Keeps the :latest
# workflow; no per-deploy SHA tags. (A Cloud Run revision is otherwise pinned to
# the digest captured when it was created, so re-pushing the same :latest tag
# alone never redeploys — the spec string is unchanged.)
data "google_artifact_registry_docker_image" "api" {
  location      = var.ar_region
  repository_id = google_artifact_registry_repository.main.repository_id
  image_name    = "career_caddy_api:${var.image_tag}"
}

data "google_artifact_registry_docker_image" "frontend" {
  location      = var.ar_region
  repository_id = google_artifact_registry_repository.main.repository_id
  image_name    = "career_caddy_frontend:${var.image_tag}"
}

data "google_artifact_registry_docker_image" "ai" {
  location      = var.ar_region
  repository_id = google_artifact_registry_repository.main.repository_id
  image_name    = "career_caddy_ai:${var.image_tag}"
}
