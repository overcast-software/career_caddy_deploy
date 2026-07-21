# Analytics host — a single Compute Engine VM running dockerized Metabase (BI).
#
# This is NOT part of the Career Caddy product deploy; it's the maintainer's
# internal analytics box. It lives in THIS project so it shares one terraform
# state — a separate root against the same project would drift and risk
# re-managing the Cloud Run / Cloud SQL resources. Metabase reads the BigQuery
# request-log dataset (see logging.tf) + the Cloud SQL job_hunting DB.
#
# Delivery is terraform-native (NO ansible): the Metabase + caddy + cloud-sql-proxy
# compose stack is rendered by templatefile() (templates/analytics-*.tftpl) and
# shipped in the VM's startup script; a systemd unit re-converges it on boot. The
# only secret (Metabase's app-DB password) comes from Secret Manager via the VM's
# attached SA — never metadata. `tofu apply` is the deploy; redeliver a template
# change by re-running the startup script (see the template header) or rebooting.
#
# Metabase's own metadata DB = a `metabase` database on the existing Cloud SQL
# instance (decision 2026-07-21: e2-small + app-DB on Cloud SQL is the leanest
# always-on shape; PACA stays OFF GCP so this box is Metabase-only). Analytics
# data sources: BigQuery (career_caddy_logs) + Cloud SQL (job_hunting).
#
# Gate model: NO GCP IAP in front, NO load balancer. Metabase's own login is the
# gate. caddy ON the VM terminates TLS (automatic certs) and reverse-proxies
# bi.careercaddy.online -> Metabase. Admin/SSH is IAP-tunnel only (no public 22).
#
# OFF by default (enable_analytics_host = false) so a reference apply stays lean.

locals {
  analytics_host = var.enable_analytics_host ? 1 : 0
  analytics_zone = "${var.region}-a"

  analytics_site_host = "bi.${var.domain_name}"
  analytics_stack_dir = "/opt/stacks/analytics"

  # Image pins. Metabase matches the known-good omarchy version; bump deliberately.
  metabase_image        = "metabase/metabase:v0.51.5"
  caddy_image           = "caddy:2-alpine"
  cloudsql_proxy_image  = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"
  metabase_jvm_max_heap = "1g" # fits an e2-small (2 GB) with the app-DB off-box

  metabase_db_name = "metabase"
  metabase_db_user = "metabase"
}

# Dedicated identity the VM runs as. Same-project, so it just attaches directly
# (no cross-project IAM). Reads BigQuery (career_caddy_logs) for Metabase
# dashboards + Cloud SQL for the Postgres data source + its own app DB.
resource "google_service_account" "analytics_host" {
  count = local.analytics_host

  account_id   = "${local.name}-analytics-host"
  display_name = "Career Caddy analytics host (Metabase VM)"
}

# BigQuery read for Metabase: dataViewer on the request-log dataset (least
# privilege, dataset-scoped) + jobUser at the project to run query jobs.
# NOTE: requires enable_log_export = true so local.log_dataset_id exists.
resource "google_bigquery_dataset_iam_member" "analytics_bq_view" {
  count = local.analytics_host

  dataset_id = local.log_dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.analytics_host[0].email}"
}

resource "google_project_iam_member" "analytics_bq_jobuser" {
  count = local.analytics_host

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.analytics_host[0].email}"
}

# Cloud SQL client so the proxy on the VM can reach career-caddy-pg-us-west1
# (both the job_hunting analytics source and Metabase's own `metabase` app DB).
resource "google_project_iam_member" "analytics_sql_client" {
  count = local.analytics_host

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.analytics_host[0].email}"
}

# --- Metabase app DB (its metadata store) on the existing Cloud SQL instance ---
# A separate database + login role on google_sql_database_instance.main — NOT the
# prod job_hunting schema. Keeps Metabase's questions/dashboards/users isolated.
resource "random_password" "metabase_appdb" {
  count = local.analytics_host

  length  = 32
  special = false # keep it shell/URL-safe for the compose .env
}

resource "google_sql_database" "metabase" {
  count = local.analytics_host

  name     = local.metabase_db_name
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "metabase" {
  count = local.analytics_host

  name     = local.metabase_db_user
  instance = google_sql_database_instance.main.name
  password = random_password.metabase_appdb[0].result
}

# The app-DB password in Secret Manager; the VM SA fetches it at boot (keyless).
resource "google_secret_manager_secret" "metabase_db" {
  count = local.analytics_host

  secret_id = "${local.name}-metabase-db-pass"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "metabase_db" {
  count = local.analytics_host

  secret      = google_secret_manager_secret.metabase_db[0].id
  secret_data = random_password.metabase_appdb[0].result
}

resource "google_secret_manager_secret_iam_member" "analytics_metabase_db" {
  count = local.analytics_host

  secret_id = google_secret_manager_secret.metabase_db[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.analytics_host[0].email}"
}

# Stable external IP so the bi. DNS A record doesn't move across reboots.
resource "google_compute_address" "analytics_host" {
  count = local.analytics_host

  name   = "${local.name}-analytics-host"
  region = var.region
}

# The VM. e2-small (2 GB) covers Metabase (JVM, -Xmx1g) + caddy + the proxy now
# that the app DB is on Cloud SQL and PACA is off-box; bump var.analytics_machine_type
# if dashboards get heavy.
resource "google_compute_instance" "analytics_host" {
  count = local.analytics_host

  name         = "${local.name}-analytics-host"
  machine_type = var.analytics_machine_type
  zone         = local.analytics_zone
  labels       = local.common_labels
  tags         = ["analytics-host"]

  deletion_protection       = var.deletion_protection
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.analytics_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.analytics_host[0].address
    }
  }

  service_account {
    email = google_service_account.analytics_host[0].email
    # cloud-platform scope; actual access is governed by the IAM roles above
    # (BQ dataViewer/jobUser, cloudsql.client, secretAccessor on the app-DB secret).
    scopes = ["cloud-platform"]
  }

  # Render + ship the Metabase compose stack. Docker install, compose/Caddyfile
  # decode, keyless Secret-Manager fetch of the app-DB password, and a systemd
  # unit that runs `docker compose up -d`. See templates/analytics-startup.sh.tftpl.
  metadata_startup_script = templatefile("${path.module}/templates/analytics-startup.sh.tftpl", {
    stack_dir  = local.analytics_stack_dir
    project_id = var.project_id
    secret_id  = google_secret_manager_secret.metabase_db[0].secret_id

    compose_b64 = base64encode(templatefile("${path.module}/templates/analytics-compose.yml.tftpl", {
      metabase_image           = local.metabase_image
      caddy_image              = local.caddy_image
      cloudsql_proxy_image     = local.cloudsql_proxy_image
      metabase_site_host       = local.analytics_site_host
      metabase_db_name         = local.metabase_db_name
      metabase_db_user         = local.metabase_db_user
      metabase_jvm_max_heap    = local.metabase_jvm_max_heap
      cloudsql_connection_name = google_sql_database_instance.main.connection_name
    }))

    caddy_b64 = base64encode(templatefile("${path.module}/templates/analytics-caddyfile.tftpl", {
      metabase_site_host = local.analytics_site_host
    }))
  })

  depends_on = [
    google_project_service.apis,
    google_sql_database.metabase,
    google_sql_user.metabase,
    google_secret_manager_secret_version.metabase_db,
    google_secret_manager_secret_iam_member.analytics_metabase_db,
  ]
}

# Public web ingress: 80 (ACME HTTP-01 + http->https redirect) + 443 (caddy TLS).
# The gate is Metabase's own login — deliberately no LB/IAP in front.
resource "google_compute_firewall" "analytics_web" {
  count = local.analytics_host

  name    = "${local.name}-analytics-web"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["analytics-host"]
}

# SSH ONLY via IAP TCP forwarding (`gcloud compute ssh --tunnel-through-iap`) —
# no public 22.
resource "google_compute_firewall" "analytics_ssh_iap" {
  count = local.analytics_host

  name    = "${local.name}-analytics-ssh-iap"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # Google IAP TCP-forwarding range
  target_tags   = ["analytics-host"]
}

# --- outputs (null when off) ------------------------------------------------
output "analytics_host_ip" {
  description = "Static external IP of the analytics VM — point the bi.careercaddy.online A record here (null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? google_compute_address.analytics_host[0].address : null
}

output "analytics_host_sa" {
  description = "Service account the analytics VM runs as (reads BigQuery + Cloud SQL; null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? google_service_account.analytics_host[0].email : null
}

output "analytics_metabase_url" {
  description = "Canonical Metabase URL once DNS + the ACME cert are live (null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? "https://${local.analytics_site_host}" : null
}
