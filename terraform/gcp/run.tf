# Cloud Run services — one per compose container.
#
# LB-fronted services (api/events/frontend/mcp) are created via for_each; chat
# and worker are explicit because they're internal and shaped differently.

resource "google_cloud_run_v2_service" "lb" {
  for_each = local.lb_services

  name                = each.key
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.deletion_protection

  template {
    service_account = google_service_account.run.email
    timeout         = each.value.timeout

    scaling {
      min_instance_count = each.value.min_scale
      max_instance_count = each.value.max_scale
    }

    dynamic "volumes" {
      for_each = each.value.uses_db ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }
    }

    containers {
      image   = each.value.image
      command = each.value.command

      ports {
        container_port = each.value.port
      }

      resources {
        limits = { cpu = each.value.cpu, memory = each.value.memory }
        # Explicit per service in locals.tf. Leaving this unset inherits
        # cpu_idle=false (CPU always allocated), which bills round the clock
        # on every min_scale>0 service and raises no error to tell you.
        cpu_idle = each.value.cpu_idle
      }

      # Plain config env.
      dynamic "env" {
        for_each = each.value.environment
        content {
          name  = env.key
          value = env.value
        }
      }

      # api-only wiring: the internal chat URL (IAM-authenticated) + Cloud Tasks
      # producer config (CC-169). CC_TASKS_* let api enqueue cover-letter work to
      # the queue, which pushes it (OIDC) to the IAM-private `tasks` service.
      dynamic "env" {
        for_each = each.key == "api" ? {
          CHAT_SERVICE_URL     = google_cloud_run_v2_service.chat.uri
          CC_TASKS_ENABLED     = "True"
          GOOGLE_CLOUD_PROJECT = var.project_id
          CC_TASKS_LOCATION    = var.region
          CC_TASKS_QUEUE_ID    = google_cloud_tasks_queue.default.name
          CC_TASKS_HANDLER_URL = google_cloud_run_v2_service.tasks.uri
          CC_TASKS_INVOKER_SA  = google_service_account.tasks_invoker.email
        } : {}
        content {
          name  = env.key
          value = env.value
        }
      }

      # Secret env from Secret Manager.
      dynamic "env" {
        for_each = { for k in each.value.secret_keys : k => k if contains(keys(local.secret_ids), k) }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = local.secret_ids[env.key]
              version = "latest"
            }
          }
        }
      }

      # CC-204 Wasabi creds (api only) — separate map from local.secret_ids.
      # Empty when the feature is off. Only api writes the upload, so only api
      # gets these here; the tasks service wires them in tasks.tf.
      dynamic "env" {
        for_each = each.key == "api" ? local.wasabi_secret_ids : {}
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      dynamic "volume_mounts" {
        for_each = each.value.uses_db ? [1] : []
        content {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }
  }


  # CC-186 — converge the perpetual `scaling: 0 -> null` diff.
  #
  # The Cloud Run v2 API ALWAYS returns a SERVICE-level `scaling` block
  # (manual_instance_count = 0, min_instance_count = 0). This module does not
  # declare one, so every plan reported it as drift and `tofu plan` read
  # "6 to change" forever without ever converging. Verified 2026-09-07: that
  # was the ONLY change in a clean plan across all six services.
  #
  # Ignored rather than declared, deliberately. Declaring the block means
  # writing `manual_instance_count`, which is the MANUAL-scaling surface —
  # setting it to make a cosmetic diff go away risks moving a service off
  # request-based scaling, which is a real behaviour change to silence a
  # no-op. Ignoring cannot change infrastructure.
  #
  # This masks NOTHING this module manages: min/max live in the TEMPLATE-level
  # `template { scaling { ... } }` block above, which is a different attribute
  # and is still fully diffed. If service-level scaling is ever adopted on
  # purpose, delete this and declare it properly.
  lifecycle {
    ignore_changes = [scaling]
  }

  depends_on = [google_project_service.apis, google_secret_manager_secret_version.app]
}

# --- chat: internal LLM service, invoked by api via IAM (no LB) --------------

resource "google_cloud_run_v2_service" "chat" {
  name                = "chat"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"   # reachable, but IAM allows only the runtime SA
  deletion_protection = var.deletion_protection # stateless POC service — allow teardown

  template {
    service_account = google_service_account.run.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image   = local.images.ai
      command = ["uv", "run", "caddy-chat"]

      ports {
        container_port = 8000
      }

      resources {
        limits = { cpu = "1", memory = "1Gi" }
        # Request-driven: chat only works while api is calling it. Already
        # min_scale=0, so this just stops it billing full CPU for the idle
        # tail of each scale-down.
        cpu_idle = true
      }

      env {
        name  = "CC_API_BASE_URL"
        value = local.api_base_url
      }
      env {
        name  = "CHAT_HOST"
        value = "0.0.0.0"
      }
      env {
        name  = "CHAT_PORT"
        value = "8000"
      }
      env {
        name  = "CHAT_MODEL"
        value = "openai:gpt-4o-mini"
      }


      dynamic "env" {
        for_each = { for k in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"] : k => k if contains(keys(local.secret_ids), k) }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = local.secret_ids[env.key]
              version = "latest"
            }
          }
        }
      }
    }
  }



  # CC-186 — converge the perpetual `scaling: 0 -> null` diff.
  #
  # The Cloud Run v2 API ALWAYS returns a SERVICE-level `scaling` block
  # (manual_instance_count = 0, min_instance_count = 0). This module does not
  # declare one, so every plan reported it as drift and `tofu plan` read
  # "6 to change" forever without ever converging. Verified 2026-09-07: that
  # was the ONLY change in a clean plan across all six services.
  #
  # Ignored rather than declared, deliberately. Declaring the block means
  # writing `manual_instance_count`, which is the MANUAL-scaling surface —
  # setting it to make a cosmetic diff go away risks moving a service off
  # request-based scaling, which is a real behaviour change to silence a
  # no-op. Ignoring cannot change infrastructure.
  #
  # This masks NOTHING this module manages: min/max live in the TEMPLATE-level
  # `template { scaling { ... } }` block above, which is a different attribute
  # and is still fully diffed. If service-level scaling is ever adopted on
  # purpose, delete this and declare it properly.
  lifecycle {
    ignore_changes = [scaling]
  }

  depends_on = [google_project_service.apis, google_secret_manager_secret_version.app]
}

# --- custom domain: apex -> frontend SPA (api + mcp path-routed same-origin) --
# careercaddy.online verified in Search Console under the deploying gcloud user
# account (2026-07-14, promoting this env to prod). The apex maps to the frontend
# Cloud Run service, whose nginx path-routes /api, /api/v1/events, and /mcp
# same-origin to the siblings — so the whole app (incl. the public MCP at /mcp) is
# reachable on the apex. No per-service subdomains: api.* and mcp.* are both retired.
# Google provisions a managed cert once the apex A/AAAA records (surfaced in
# .status) resolve.
resource "google_cloud_run_domain_mapping" "apex" {
  name     = var.domain_name
  location = var.region

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.lb["frontend"].name
  }
}

# The apex A/AAAA records Google expects — set these at Namecheap for host @
# (replacing the current apex A 192.3.252.74). Apex can't CNAME → 4x A + 4x AAAA.
output "domain_mapping_records" {
  description = "Apex A/AAAA DNS records to set at Namecheap for the frontend domain mapping (host @)."
  value       = google_cloud_run_domain_mapping.apex.status[0].resource_records
}
