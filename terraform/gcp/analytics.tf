# Analytics — Metabase (BI) as a Cloud Run service.
#
# This is NOT part of the product deploy; it's the maintainer's internal analytics
# instance. It lives in THIS project so it shares one terraform state. Metabase
# reads the BigQuery request-log dataset (see logging.tf) + the Cloud SQL
# job_hunting DB.
#
# Cloud Run (not a VM) — decision 2026-07-21, after re-litigating the VM vs
# Cloud Run tradeoff:
#   - TLS/routing via a Cloud Run DOMAIN MAPPING (already the apex's mechanism) —
#     managed cert, NO load balancer, NO caddy, NO VM to patch.
#   - Use is on-demand (interactive BI + an operator-side Slack bot that pulls
#     chart PNGs); there are NO native scheduled subscriptions, so cpu_idle=true
#     is fine and idle cost is ~memory-only — comparable to a small VM but with
#     zero box to run. Rolls with `tofu apply` like every other service.
#   - Metabase's own metadata DB = a `metabase` database/user on the existing
#     Cloud SQL instance, reached via a cloud-sql-proxy SIDECAR (Metabase's JDBC
#     can't use the Cloud Run /cloudsql unix socket). BigQuery via the service's
#     own SA (ADC). Both keyless.
#
# Gate model: Metabase's own login (public invoker; no LB/IAP). Off by default
# (enable_analytics_host = false); enabling needs enable_log_export = true.

locals {
  analytics          = var.enable_analytics_host ? 1 : 0
  metabase_site_host = "bi.${var.domain_name}"
}

# Dedicated runtime identity — least privilege (keeps BigQuery access off the
# shared api/run SA).
resource "google_service_account" "metabase" {
  count = local.analytics

  account_id   = "${local.name}-metabase"
  display_name = "Career Caddy Metabase (BI) Cloud Run service"
}

# BigQuery read: dataViewer on the request-log dataset + jobUser to run queries.
# NOTE: requires enable_log_export = true so local.log_dataset_id exists.
resource "google_bigquery_dataset_iam_member" "metabase_bq_view" {
  count = local.analytics

  dataset_id = local.log_dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.metabase[0].email}"
}

resource "google_project_iam_member" "metabase_bq_jobuser" {
  count = local.analytics

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.metabase[0].email}"
}

# Cloud SQL client for the proxy sidecar (job_hunting source + the metabase app DB).
resource "google_project_iam_member" "metabase_sql_client" {
  count = local.analytics

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.metabase[0].email}"
}

# --- Metabase app DB (its metadata store) on the existing Cloud SQL instance ---
# A separate database + login role — NOT the prod job_hunting schema.
resource "random_password" "metabase_appdb" {
  count = local.analytics

  length  = 32
  special = false
}

resource "google_sql_database" "metabase" {
  count = local.analytics

  name     = "metabase"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "metabase" {
  count = local.analytics

  name     = "metabase"
  instance = google_sql_database_instance.main.name
  password = random_password.metabase_appdb[0].result
}

resource "google_secret_manager_secret" "metabase_db" {
  count = local.analytics

  secret_id = "${local.name}-metabase-db-pass"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "metabase_db" {
  count = local.analytics

  secret      = google_secret_manager_secret.metabase_db[0].id
  secret_data = random_password.metabase_appdb[0].result
}

resource "google_secret_manager_secret_iam_member" "metabase_db" {
  count = local.analytics

  secret_id = google_secret_manager_secret.metabase_db[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.metabase[0].email}"
}

# --- Metabase Cloud Run service ---------------------------------------------
resource "google_cloud_run_v2_service" "metabase" {
  count = local.analytics

  name                = "metabase"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.deletion_protection

  template {
    service_account = google_service_account.metabase[0].email

    scaling {
      min_instance_count = 1 # Metabase boots slowly — keep one warm (no cold starts)
      max_instance_count = 1 # single instance against one app DB
    }

    # Metabase (JVM), the ingress container. cpu_idle=true: CPU billed only during
    # requests (on-demand use, no native scheduled subscriptions) → idle ~memory-only.
    containers {
      name  = "metabase"
      image = var.metabase_image

      ports {
        container_port = 3000
      }

      resources {
        limits            = { cpu = "1", memory = "2Gi" }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "MB_SITE_URL"
        value = "https://${local.metabase_site_host}"
      }
      env {
        name  = "MB_DB_TYPE"
        value = "postgres"
      }
      env {
        name  = "MB_DB_HOST"
        value = "127.0.0.1" # the cloud-sql-proxy sidecar (shared localhost)
      }
      env {
        name  = "MB_DB_PORT"
        value = "5432"
      }
      env {
        name  = "MB_DB_DBNAME"
        value = "metabase"
      }
      env {
        name  = "MB_DB_USER"
        value = "metabase"
      }
      env {
        name = "MB_DB_PASS"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.metabase_db[0].secret_id
            version = "latest"
          }
        }
      }

      # Metabase first-boot runs its own app-DB migrations — allow a generous
      # startup budget (~5 min) before Cloud Run gives up.
      startup_probe {
        http_get {
          path = "/api/health"
          port = 3000
        }
        initial_delay_seconds = 30
        timeout_seconds       = 5
        period_seconds        = 15
        failure_threshold     = 20
      }

      depends_on = ["cloudsql-proxy"]
    }

    # Keyless Cloud SQL bridge — Metabase's JDBC can't use the /cloudsql socket, so
    # the proxy exposes the instance on localhost:5432. Auths via the service SA (ADC).
    containers {
      name  = "cloudsql-proxy"
      image = var.cloudsql_proxy_image
      args = [
        "--port=5432",
        "--health-check",
        "--http-address=0.0.0.0",
        "--http-port=9090",
        google_sql_database_instance.main.connection_name,
      ]

      resources {
        limits   = { cpu = "1", memory = "512Mi" }
        cpu_idle = true
      }

      startup_probe {
        http_get {
          path = "/startup"
          port = 9090
        }
        initial_delay_seconds = 5
        timeout_seconds       = 5
        period_seconds        = 5
        failure_threshold     = 12
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.metabase_db,
    google_sql_database.metabase,
    google_sql_user.metabase,
  ]
}

# Public — the gate is Metabase's own login (like the user-facing api/frontend).
resource "google_cloud_run_v2_service_iam_member" "metabase_public" {
  count = local.analytics

  name     = google_cloud_run_v2_service.metabase[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Managed TLS for bi.<domain> — same mechanism as the apex, no LB/caddy.
resource "google_cloud_run_domain_mapping" "metabase" {
  count = local.analytics

  name     = local.metabase_site_host
  location = var.region

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.metabase[0].name
  }
}

# --- outputs (null when off) ------------------------------------------------
output "analytics_metabase_url" {
  description = "Metabase URL once DNS + the managed cert are live (null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? "https://${local.metabase_site_host}" : null
}

output "analytics_metabase_dns" {
  description = "DNS record(s) to set at Namecheap for bi.<domain> (the Metabase domain mapping; null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? google_cloud_run_domain_mapping.metabase[0].status[0].resource_records : null
}
