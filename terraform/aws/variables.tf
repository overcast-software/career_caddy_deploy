variable "region" {
  description = "AWS region to deploy the POC stack in."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain (managed at Namecheap)."
  type        = string
  default     = "careercaddy.online"
}

variable "poc_subdomain" {
  description = "Label prefixed to the apex for the POC. Yields <sub>.<domain>."
  type        = string
  default     = "aws"
}

variable "image_tag" {
  description = "GHCR image tag deployed across all services (a git SHA in prod, or 'latest')."
  type        = string
  default     = "latest"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread public/private subnets across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_version" {
  description = "PostgreSQL engine major version (matches the compose db image)."
  type        = string
  default     = "18"
}

variable "openai_api_key" {
  description = "Optional OpenAI key for the chat service. Empty = chat runs but LLM calls fail."
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
