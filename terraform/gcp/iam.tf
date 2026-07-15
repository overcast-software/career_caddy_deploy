# One runtime service account for all Cloud Run services. Granted secret access +
# Cloud SQL client. Public services allow unauthenticated invocation (fronted by
# the LB); the internal `chat` service is invokable only by this SA (api->chat).

resource "google_service_account" "run" {
  account_id   = "${local.name}-run"
  display_name = "Career Caddy Cloud Run runtime"
}

resource "google_project_iam_member" "run_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run.email}"
}

# Grant the runtime SA access to each secret it may read.
resource "google_secret_manager_secret_iam_member" "run_access" {
  for_each  = google_secret_manager_secret.app
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run.email}"
}

# Public (LB-fronted) services: allow unauthenticated invocation.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  for_each = local.lb_services
  location = var.region
  name     = google_cloud_run_v2_service.lb[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Internal chat: only the runtime SA (i.e. the api service) may invoke it.
resource "google_cloud_run_v2_service_iam_member" "chat_invoker" {
  location = var.region
  name     = google_cloud_run_v2_service.chat.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.run.email}"
}
