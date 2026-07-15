# Career Caddy — provider-neutral representation.
#
# This module models the real Docker Compose stack 1:1 using only the `null`
# provider. There is no cloud provider here on purpose: Brainboard renders these
# as neutral resource blocks so you can see the raw component graph, independent
# of any cloud. It is a visualization artifact — never `apply`'d for real infra.

terraform {
  required_version = ">= 1.5"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
