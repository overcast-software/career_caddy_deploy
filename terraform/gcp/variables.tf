variable "deletion_protection" {
  type        = bool
  default     = false # lab: allow teardown. A prod tfvars would set true.
  description = "Destroy guard for managed resources (Cloud Run, Cloud SQL)."
}

variable "project_id" {
  description = "GCP project ID to deploy the POC into."
  type        = string
}

variable "region" {
  description = "GCP region for compute — Cloud Run, Cloud SQL, Cloud Tasks (us-west1, west coast)."
  type        = string
  default     = "us-west1"
}

variable "ar_region" {
  description = "Region of the Artifact Registry repo. Decoupled from var.region so compute can live in us-west1 while the images stay in us-central1 — Cloud Run pulls cross-region (no re-mirror needed)."
  type        = string
  default     = "us-central1"
}

variable "domain_name" {
  description = "Apex domain (managed at Namecheap)."
  type        = string
  default     = "careercaddy.online"
}

variable "image_tag" {
  description = "Image tag deployed across all services (a git SHA, or 'latest')."
  type        = string
  default     = "latest"
}

variable "db_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-f1-micro"
}

variable "postgres_version" {
  description = "Cloud SQL Postgres version enum."
  type        = string
  default     = "POSTGRES_16" # Cloud SQL max; the compose db is 18, closest managed is 16
}

variable "openai_api_key" {
  description = "Optional OpenAI key for the chat service."
  type        = string
  default     = ""
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Optional Anthropic key for the chat service."
  type        = string
  default     = ""
  sensitive   = true
}

# Outbound email (SMTP). When email_host_password is set, the api service
# switches from the console backend to real SMTP so signup/welcome + admin-notify
# mail actually sends. host/port/user are plain env; the password lands in Secret
# Manager (see secrets.tf). Defaults target Purelymail.
variable "email_host" {
  description = "SMTP host for outbound mail (e.g. Purelymail: smtp.purelymail.com)."
  type        = string
  default     = "smtp.purelymail.com"
}

variable "email_port" {
  description = "SMTP port (587 = STARTTLS/TLS, 465 = implicit SSL)."
  type        = number
  default     = 587
}

variable "email_host_user" {
  description = "SMTP auth user — the sending mailbox (e.g. noreply@yourdomain)."
  type        = string
  default     = ""
}

variable "email_host_password" {
  description = "SMTP mailbox/app password. Empty = console backend (no real send)."
  type        = string
  default     = ""
  sensitive   = true
}

# Request-log export (see logging.tf). Off by default — the consumer lives outside
# this config, so a default apply should not create an undrained Pub/Sub topic.
variable "enable_log_export" {
  description = "Route Cloud Run request logs to a BigQuery dataset (see logging.tf) for SQL/BI. Off by default."
  type        = bool
  default     = false
}

variable "log_export_service" {
  description = "Which Cloud Run service's request log to export. Default `frontend` — the apex maps to it, so its log sees every request (api/events/mcp are same-origin internal hops)."
  type        = string
  default     = "frontend"
}

# Analytics — Metabase (BI) as a Cloud Run service (see analytics.tf). Gated by
# Metabase's own login; TLS via a Cloud Run domain mapping (no LB/caddy/VM). Off
# by default. Enabling it needs enable_log_export = true (Metabase reads the
# BigQuery request-log dataset).
variable "enable_analytics_host" {
  description = "Provision the Metabase (BI) Cloud Run service + domain mapping (analytics.tf). Off by default. Requires enable_log_export=true for the BigQuery dataset it reads."
  type        = bool
  default     = false
}

variable "metabase_image" {
  description = "Metabase container image. Public Docker Hub by default; mirror to Artifact Registry for pull reliability if desired."
  type        = string
  default     = "docker.io/metabase/metabase:v0.51.5"
}

variable "cloudsql_proxy_image" {
  description = "Cloud SQL Auth Proxy v2 image for the Metabase app-DB sidecar."
  type        = string
  default     = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1"
}
