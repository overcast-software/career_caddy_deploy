# Cloud SQL for PostgreSQL (replaces the `db` compose service). Cloud Run reaches
# it over the built-in Cloud SQL socket at /cloudsql/<connection_name> — no VPC
# connector needed.

resource "random_password" "db" {
  length  = 32
  special = false # keep DATABASE_URL free of chars needing URL-encoding
}

resource "random_password" "secret_key" {
  length  = 64
  special = false
}

resource "google_sql_database_instance" "main" {
  # Region baked into the name: changing regions destroys + recreates this
  # instance, and Cloud SQL reserves a deleted instance name for ~a week — a
  # region-suffixed name sidesteps that collision (career-caddy-pg-us-west1).
  name             = "${local.name}-pg-${var.region}"
  database_version = var.postgres_version
  region           = var.region

  settings {
    tier              = var.db_tier
    edition           = "ENTERPRISE" # db-f1-micro is only valid on ENTERPRISE; the
    # API now defaults new instances to ENTERPRISE_PLUS, which rejects shared-core tiers.
    availability_type = "ZONAL" # POC: single zone
    deletion_protection_enabled = false # API-level lock; POC — allow teardown
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled = true # reachable by the Cloud SQL socket proxy; no authorized networks
    }

    backup_configuration {
      enabled = true
    }
  }

  deletion_protection = false # POC — allow teardown

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "app" {
  name     = "job_hunting"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  name     = "postgres"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}
