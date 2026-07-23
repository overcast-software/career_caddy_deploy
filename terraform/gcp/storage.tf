# Wasabi (S3-compatible) blob storage for uploaded resumes — CC-204.
#
# The api service persists the uploaded resume to default_storage (Resume.file)
# and enqueues only the resume_id; the tasks service's resume_parse_job worker
# reads the blob back from the SAME bucket. So BOTH services need the Wasabi
# creds + endpoint/region/bucket env. Wasabi is out-of-band (not a GCP
# resource) — this file only wires the credentials/env into Cloud Run; Doug
# provisions the bucket + access key (see the PR checklist).
#
# Reuses Doug's existing Wasabi conventions (the wasabi backup scripts + the
# tofu remote-state backend): endpoint https://s3.us-west-1.wasabisys.com,
# region us-west-1, path-style addressing. Co-located with the us-west1 GCP
# compute.
#
# ENV-VAR CONTRACT (must match the api settings.py STORAGES block exactly):
#   AWS_STORAGE_BUCKET_NAME  — plain env; presence flips api settings to S3
#   AWS_S3_ENDPOINT_URL      — plain env
#   AWS_S3_REGION_NAME       — plain env
#   AWS_ACCESS_KEY_ID        — Secret Manager
#   AWS_SECRET_ACCESS_KEY    — Secret Manager

variable "wasabi_bucket" {
  description = "Wasabi bucket for uploaded resumes (CC-204). Empty = feature off (api falls back to local FileSystemStorage)."
  type        = string
  default     = ""
}

variable "wasabi_endpoint_url" {
  description = "Wasabi S3 endpoint. Region-specific host; us-west-1 co-locates with the GCP compute."
  type        = string
  default     = "https://s3.us-west-1.wasabisys.com"
}

variable "wasabi_region" {
  description = "Wasabi region (matches the endpoint host)."
  type        = string
  default     = "us-west-1"
}

variable "wasabi_access_key_id" {
  description = "Wasabi access key id scoped to the resume bucket. Lands in Secret Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "wasabi_secret_access_key" {
  description = "Wasabi secret access key. Lands in Secret Manager."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  # Feature is on only when a bucket + both creds are supplied.
  wasabi_enabled = var.wasabi_bucket != "" && var.wasabi_access_key_id != "" && var.wasabi_secret_access_key != ""

  # Wasabi creds → Secret Manager (same shape as secrets.tf's app secrets).
  wasabi_secret_values = local.wasabi_enabled ? {
    AWS_ACCESS_KEY_ID     = var.wasabi_access_key_id
    AWS_SECRET_ACCESS_KEY = var.wasabi_secret_access_key
  } : {}

  # Plain (non-secret) env both api + tasks need to point at the bucket.
  wasabi_env = local.wasabi_enabled ? {
    AWS_STORAGE_BUCKET_NAME = var.wasabi_bucket
    AWS_S3_ENDPOINT_URL     = var.wasabi_endpoint_url
    AWS_S3_REGION_NAME      = var.wasabi_region
  } : {}

  # Secret keys both services reference via value_source.secret_key_ref.
  wasabi_secret_keys = keys(local.wasabi_secret_values)
}

resource "google_secret_manager_secret" "wasabi" {
  for_each  = nonsensitive(toset(keys(local.wasabi_secret_values)))
  secret_id = "${local.name}-${lower(each.key)}"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "wasabi" {
  for_each    = nonsensitive(toset(keys(local.wasabi_secret_values)))
  secret      = google_secret_manager_secret.wasabi[each.key].id
  secret_data = local.wasabi_secret_values[each.key]
}

# key -> secret id, for Cloud Run env value_source (parallels local.secret_ids).
locals {
  wasabi_secret_ids = { for k, s in google_secret_manager_secret.wasabi : k => s.secret_id }
}

# Grant the runtime SA (used by BOTH the api and tasks services) read access to
# the Wasabi creds. Mirrors iam.tf's run_access grant for the app secrets.
resource "google_secret_manager_secret_iam_member" "wasabi_run_access" {
  for_each  = google_secret_manager_secret.wasabi
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run.email}"
}
