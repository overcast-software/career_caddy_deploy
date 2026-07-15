# Career Caddy on AWS — POC deployment (aws.careercaddy.online).
#
# A parallel ECS Fargate stack that pulls the existing public GHCR images and
# stands up Career Caddy on a subdomain, leaving the racknerd prod stack
# untouched. State + plan/apply are managed by Brainboard (no local backend).

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.region
}
