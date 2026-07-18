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

# Analytics / ops host (see analytics_host.tf) — a single VM running Metabase +
# PACA, gated by each app's own login (Metabase Google Sign-In / PACA password),
# no IAP/LB. Off by default. Enabling it needs enable_log_export = true (Metabase
# reads the BigQuery request-log dataset).
variable "enable_analytics_host" {
  description = "Provision the Metabase + PACA analytics/ops VM (analytics_host.tf). Off by default. Requires enable_log_export=true for the BigQuery dataset the VM reads."
  type        = bool
  default     = false
}

variable "analytics_machine_type" {
  description = "Machine type for the analytics VM. e2-medium (4GB) fits Metabase + PACA; bump to e2-standard-2 (8GB) if co-hosting more."
  type        = string
  default     = "e2-medium"
}

variable "analytics_disk_gb" {
  description = "Boot disk size (GB) for the analytics VM."
  type        = number
  default     = 20
}
