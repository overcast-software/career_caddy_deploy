variable "image_tag" {
  description = "Container image tag deployed across all services."
  type        = string
  default     = "latest"
}

variable "postgres_version" {
  description = "PostgreSQL major version (matches the compose db image)."
  type        = string
  default     = "18"
}

variable "domain" {
  description = "Apex domain the ingress serves."
  type        = string
  default     = "careercaddy.online"
}
