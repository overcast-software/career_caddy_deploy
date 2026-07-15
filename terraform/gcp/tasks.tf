# Cloud Tasks async dispatch (CC-169) — replaces the django-q2 worker for
# push-shaped work. Producer (api) enqueues an HTTP task; Cloud Tasks pushes it,
# with an OIDC token, to an IAM-private `tasks` Cloud Run service running the
# SAME api image ("one image, two roles"). Scales to zero; managed retries.
#
# NOTE: hand-written for the CTO demo (not tangled from a lesson yet). Back-port
# into a lesson (11-cloud-tasks or fold into 05/08) once it settles.

resource "google_project_service" "cloudtasks" {
  service            = "cloudtasks.googleapis.com"
  disable_on_destroy = false
}

# The queue: rate cap protects the shared OpenAI quota + DB pool; retry policy
# gives at-least-once delivery with backoff.
resource "google_cloud_tasks_queue" "default" {
  name     = "${local.name}-tasks"
  location = var.region

  rate_limits {
    max_dispatches_per_second = 5
    max_concurrent_dispatches = 10
  }

  retry_config {
    max_attempts  = 5
    min_backoff   = "5s"
    max_backoff   = "300s"
    max_doublings = 3
  }

  depends_on = [google_project_service.cloudtasks]
}

# Identity Cloud Tasks assumes to mint the OIDC token when pushing to the handler.
resource "google_service_account" "tasks_invoker" {
  account_id   = "cc-tasks-invoker"
  display_name = "Cloud Tasks -> tasks service invoker"
}

# The task handler: same api image, but IAM-private (no allUsers invoker), so only
# the invoker SA's OIDC token gets in. Runs gunicorn directly (skips the
# entrypoint's migrate — api owns migrations) and scales to zero.
resource "google_cloud_run_v2_service" "tasks" {
  name                = "tasks"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL" # reachable, but IAM gates it
  deletion_protection = var.deletion_protection

  template {
    service_account = google_service_account.run.email

    scaling {
      min_instance_count = 0 # scale to zero — the whole point vs the always-on worker
      max_instance_count = 4
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image   = local.images.api
      command = ["gunicorn", "job_hunting.wsgi:application", "-c", "/app/gunicorn.conf.py"]

      ports {
        container_port = 8000
      }

      resources {
        limits = { cpu = "1", memory = "1Gi" }
      }

      dynamic "env" {
        for_each = merge(local.django_common, {
          GUNICORN_HOST             = "0.0.0.0"
          SA_SCHEMA_ON_POST_MIGRATE = "False"
          SCRAPING_ENABLED          = "False"
          USE_MCP_BROWSER_AGENT     = "False"
          EMAIL_BACKEND             = "django.core.mail.backends.console.EmailBackend"
          SCREENSHOT_DIR            = "/tmp/screenshots"
          CC_TASKS_ENABLED          = "True"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = { for k in ["SECRET_KEY", "DATABASE_URL", "OPENAI_API_KEY"] : k => k }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = local.secret_ids[env.key]
              version = "latest"
            }
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  depends_on = [google_project_service.apis, google_secret_manager_secret_version.app]
}

# Only the invoker SA may call the handler — Cloud Tasks presents its OIDC token.
resource "google_cloud_run_v2_service_iam_member" "tasks_invoker" {
  name     = google_cloud_run_v2_service.tasks.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.tasks_invoker.email}"
}

# The api runtime SA may enqueue tasks onto the queue.
resource "google_project_iam_member" "run_tasks_enqueuer" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = "serviceAccount:${google_service_account.run.email}"
}

# GOTCHA: to create a task whose oidc_token names the invoker SA, the producer
# (run SA) must be able to act AS that SA. Without this, create_task returns
# PERMISSION_DENIED even though enqueuer is granted.
resource "google_service_account_iam_member" "run_actas_tasks_invoker" {
  service_account_id = google_service_account.tasks_invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.run.email}"
}

# --- demo outputs -----------------------------------------------------------
output "tasks_queue" {
  description = "Cloud Tasks queue id (the producer enqueues here)."
  value       = google_cloud_tasks_queue.default.id
}

output "tasks_handler_url" {
  description = "IAM-private handler URL Cloud Tasks pushes to."
  value       = google_cloud_run_v2_service.tasks.uri
}

output "tasks_invoker_sa" {
  description = "SA whose OIDC token Cloud Tasks presents to the handler."
  value       = google_service_account.tasks_invoker.email
}
