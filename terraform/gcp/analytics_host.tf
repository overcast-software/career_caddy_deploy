# Analytics / ops host — a single Compute Engine VM running Metabase + PACA.
#
# This is NOT part of the Career Caddy product deploy; it's the maintainer's
# internal analytics + project-management box (Metabase for BI, PACA for the
# work board). It lives in THIS project so it shares one terraform state — a
# separate root against the same project would drift and risk re-managing the
# Cloud Run / Cloud SQL resources. Metabase reads the BigQuery request-log
# dataset (see logging.tf) + Cloud SQL; PACA is self-contained.
#
# Gate model (decision 2026-07-17): NO GCP IAP, NO load balancer. Each app is
# protected by its OWN login — Metabase's native Google Sign-In, PACA's
# username/password. caddy ON the VM terminates TLS (automatic certs) and
# reverse-proxies bi.careercaddy.online -> Metabase and plan.careercaddy.online
# -> PACA. DNS A records point straight at this VM's static IP.
#
# OFF by default (enable_analytics_host = false) so a reference apply stays lean.
# Terraform provisions the VM + its identity + firewall + a static IP only. The
# Metabase/PACA compose stacks, caddy config, and `tailscale up` are provisioning
# steps (ansible/manual, out of state — they carry app secrets). See DIYC-58/59/60.

locals {
  analytics_host = var.enable_analytics_host ? 1 : 0
  analytics_zone = "${var.region}-a"
}

# Dedicated identity the VM runs as. Same-project, so it just attaches directly
# (no cross-project IAM). Reads BigQuery (career_caddy_logs) for Metabase
# dashboards + Cloud SQL for the Postgres data source.
resource "google_service_account" "analytics_host" {
  count = local.analytics_host

  account_id   = "${local.name}-analytics-host"
  display_name = "Career Caddy analytics host (Metabase + PACA VM)"
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

# Cloud SQL client so Metabase can reach career-caddy-pg-us-west1 via the Cloud
# SQL Auth Proxy running on the VM.
resource "google_project_iam_member" "analytics_sql_client" {
  count = local.analytics_host

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.analytics_host[0].email}"
}

# Stable external IP so the bi. + plan. DNS A records don't move across reboots.
resource "google_compute_address" "analytics_host" {
  count = local.analytics_host

  name   = "${local.name}-analytics-host"
  region = var.region
}

# The VM. e2-medium (4 GB) covers Metabase (JVM) + the PACA stack per sizing;
# bump var.analytics_machine_type if BookStack/etc. is ever added.
resource "google_compute_instance" "analytics_host" {
  count = local.analytics_host

  name         = "${local.name}-analytics-host"
  machine_type = var.analytics_machine_type
  zone         = local.analytics_zone
  labels       = local.common_labels
  tags         = ["analytics-host"]

  # Deletion guard tracks the module-wide flag (a real prod box sets it true).
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
    # (BQ dataViewer/jobUser, cloudsql.client) — not by legacy scopes.
    scopes = ["cloud-platform"]
  }

  # Minimal bootstrap: install Docker + the compose plugin. The Metabase/PACA
  # compose stacks, caddy (TLS + reverse proxy), and `tailscale up` are
  # provisioned out-of-band (secrets) — see DIYC-58/59/60.
  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v docker >/dev/null 2>&1; then
      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker
    fi
    install -d -m 0755 /opt/stacks
  EOT

  depends_on = [google_project_service.apis]
}

# Public web ingress: 80 (ACME HTTP-01 + http->https redirect) + 443 (caddy
# TLS). The gate is app-level login (Metabase Google Sign-In / PACA password) —
# there is deliberately no LB/IAP in front.
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
# no public 22. Admin is also reachable over tailscale once the VM is joined.
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
  description = "Static external IP of the analytics VM — point bi. + plan.careercaddy.online A records here (null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? google_compute_address.analytics_host[0].address : null
}

output "analytics_host_sa" {
  description = "Service account the analytics VM runs as (reads BigQuery + Cloud SQL; null unless enable_analytics_host)."
  value       = var.enable_analytics_host ? google_service_account.analytics_host[0].email : null
}
