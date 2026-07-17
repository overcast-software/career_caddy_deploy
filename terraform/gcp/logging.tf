# Request-log analytics: Cloud Run request logs -> BigQuery (GCP-native, no export daemon).
#
# Cloud Run already emits a request log for every hit (logName
# `run.googleapis.com/requests`, resource `cloud_run_revision`) into Cloud
# Logging automatically. This file routes those entries into a BigQuery dataset
# so they're queryable with SQL and reachable by a BI tool (Metabase's BigQuery
# driver, Looker Studio, etc.) — with NO Pub/Sub, no forwarder process, and no
# private-network hop. The Log Router sink is fully managed; BigQuery is a public
# API, so a BI tool anywhere reaches it with a service-account key over the
# internet. (An earlier draft shipped to an on-prem ClickHouse over a tailnet;
# that transport only existed to reach the homelab store and is dropped here.)
#
# The apex domain-maps to the `frontend` service, whose nginx same-origin
# reverse-proxies /api, /api/v1/events, /mcp to the siblings — so the `frontend`
# service's request log sees EVERY request to the apex. That one service's log is
# the edge-equivalent of a classic reverse-proxy access log; api/events/mcp logs
# are internal hops (Host rewritten to the run.app URL). Hence the sink filters to
# `service_name = frontend`.
#
# OFF by default (`enable_log_export = false`) so a default apply stays lean. Flip
# `enable_log_export = true` in tfvars to turn it on. The BI reader authenticates
# with a key for the reader SA, provisioned out-of-band — never in terraform state
# (this is a public repo).
#
# Schema: Cloud Logging writes a `run_googleapis_com_requests_YYYYMMDD` table into
# the dataset (date-partitioned via bigquery_options below). Useful columns:
# timestamp, httpRequest (RECORD: requestMethod, requestUrl, status, responseSize,
# userAgent, remoteIp, serverIp, latency), resource.labels.service_name, trace.

locals {
  # Guard for all resources in this file — one boolean, evaluated once.
  log_export = var.enable_log_export ? 1 : 0

  # BigQuery dataset ids allow only letters/digits/underscores.
  log_dataset_id = "${replace(local.name, "-", "_")}_logs" # career_caddy_logs

  # The request log of the edge service (the apex maps here). Newlines are ANDed
  # by the Cloud Logging filter grammar.
  log_export_filter = <<-EOT
    resource.type = "cloud_run_revision"
    resource.labels.service_name = "${var.log_export_service}"
    logName = "projects/${var.project_id}/logs/run.googleapis.com%2Frequests"
  EOT
}

# BigQuery is only needed when the export is on.
resource "google_project_service" "bigquery" {
  count = local.log_export

  project            = var.project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

# The dataset Cloud Logging writes request-log tables into. Co-located with
# compute (us-west1). delete_contents_on_destroy tracks the same lab-vs-prod guard
# as the rest of the module: a real prod box (deletion_protection = true) refuses
# to drop populated log tables.
resource "google_bigquery_dataset" "logs" {
  count = local.log_export

  dataset_id                 = local.log_dataset_id
  project                    = var.project_id
  location                   = var.region
  labels                     = local.common_labels
  delete_contents_on_destroy = !var.deletion_protection
  description                = "Cloud Run request logs routed from Cloud Logging (frontend edge)."

  depends_on = [google_project_service.bigquery]
}

# Log Router sink: matched frontend request logs -> the dataset. `unique_writer_
# identity` mints a dedicated sink identity we grant dataEditor to below.
# use_partitioned_tables makes the destination tables date-partitioned, so queries
# that filter on a day scan only that partition (cheaper + faster).
resource "google_logging_project_sink" "cloudrun_access" {
  count = local.log_export

  name                   = "${local.name}-cloudrun-access"
  project                = var.project_id
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs[0].dataset_id}"
  filter                 = local.log_export_filter
  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

# The sink can only write once its writer identity holds dataEditor on the dataset.
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  count = local.log_export

  dataset_id = google_bigquery_dataset.logs[0].dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.cloudrun_access[0].writer_identity
}

# Read-only identity the BI tool (Metabase's BigQuery driver, wherever it runs)
# authenticates as. Key/WIF provisioned out-of-band (see header). dataViewer on
# the dataset reads the tables; jobUser at the project lets it run query jobs.
resource "google_service_account" "bq_reader" {
  count = local.log_export

  account_id   = "${local.name}-bq-reader"
  display_name = "Career Caddy BigQuery log reader (BI tool)"
}

resource "google_bigquery_dataset_iam_member" "reader_view" {
  count = local.log_export

  dataset_id = google_bigquery_dataset.logs[0].dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.bq_reader[0].email}"
}

resource "google_project_iam_member" "reader_jobuser" {
  count = local.log_export

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.bq_reader[0].email}"
}

# --- outputs (null when export is off) --------------------------------------
output "log_dataset" {
  description = "BigQuery dataset holding Cloud Run request logs (null unless enable_log_export)."
  value       = var.enable_log_export ? google_bigquery_dataset.logs[0].dataset_id : null
}

output "log_bq_reader_sa" {
  description = "Service account the BI tool authenticates as to query the logs (needs a key or WIF, provisioned out-of-band)."
  value       = var.enable_log_export ? google_service_account.bq_reader[0].email : null
}
