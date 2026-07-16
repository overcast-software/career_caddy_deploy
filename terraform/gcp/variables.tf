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
