locals {
  name = "career-caddy"

  # Production host = the apex (careercaddy.online → frontend SPA). The frontend
  # nginx path-routes /api/* and /mcp/* same-origin, so api + mcp are reachable on
  # the apex alone — no per-service subdomains (api.* and mcp.* are both retired;
  # the public MCP lives at <domain>/mcp).
  base = var.domain_name
  hosts = {
    app = local.base
  }

  # Artifact Registry image URIs. Cloud Run cannot pull ghcr.io directly, so the
  # public GHCR images are MIRRORED into this AR repo first (see README).
  ar_host = "${var.ar_region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
  # Deploy DIGEST-pinned refs resolved from each image's :${var.image_tag} at plan
  # time (data sources in registry.tf), so pushing a new :latest + `tofu apply`
  # actually rolls a new revision. ar_host retained for reference/other consumers.
  images = {
    api      = data.google_artifact_registry_docker_image.api.self_link
    frontend = data.google_artifact_registry_docker_image.frontend.self_link
    ai       = data.google_artifact_registry_docker_image.ai.self_link
  }

  # api is reached internally via the single LB host (static string → no
  # dependency cycle); callers append /api/v1/... which the URL map path-routes
  # to the api backend. chat has no LB host, so api reaches it by chat.uri.
  api_base_url = "https://${local.base}"

  # Shared Django env for api/events/worker (the api image).
  django_common = {
    DEBUG         = "False"
    ALLOWED_HOSTS = "${local.base},.run.app,localhost,127.0.0.1" # .run.app: Cloud Tasks/health + same-origin nginx Host-rewrite hit services by their run.app host
  }

  # LB-fronted services (get a serverless NEG + backend + URL-map routing).
  lb_services = {
    api = {
      image       = local.images.api
      command     = null # image entrypoint: migrate + gunicorn
      port        = 8000
      cpu         = "1"
      memory      = "1Gi"
      min_scale   = 1
      max_scale   = 4
      uses_db     = true
      health_path = "/api/v1/healthcheck/"
      environment = merge(local.django_common, {
        CORS_ALLOWED_ORIGINS = "https://${local.hosts.app}"
        CSRF_TRUSTED_ORIGINS = "https://${local.hosts.app}"
        FRONTEND_URL         = "https://${local.hosts.app}"
        INSTANCE_ORIGIN      = "https://${local.hosts.app}"
        # Real SMTP once email_host_password is supplied; until then fall back to
        # the console backend so a missing password can't 500 a signup.
        EMAIL_BACKEND   = var.email_host_password != "" ? "django.core.mail.backends.smtp.EmailBackend" : "django.core.mail.backends.console.EmailBackend"
        EMAIL_HOST      = var.email_host
        EMAIL_PORT      = tostring(var.email_port)
        EMAIL_HOST_USER = var.email_host_user
        EMAIL_USE_TLS   = "True"
        # From-address must be a real Purelymail mailbox/alias or mail is rejected;
        # default to the authenticated user, fall back to noreply@apex if unset.
        DEFAULT_FROM_EMAIL        = var.email_host_user != "" ? var.email_host_user : "noreply@${local.base}"
        SCRAPING_ENABLED          = "False"
        USE_MCP_BROWSER_AGENT     = "False"
        GUNICORN_HOST             = "0.0.0.0" # bind all interfaces; Cloud Run probe can't reach 127.0.0.1
        GUNICORN_WORKERS          = "2"
        GUNICORN_THREADS          = "4"
        SA_SCHEMA_ON_POST_MIGRATE = "True"
        SCREENSHOT_DIR            = "/tmp/screenshots"
      })
      secret_keys = ["SECRET_KEY", "DATABASE_URL", "OPENAI_API_KEY", "EMAIL_HOST_PASSWORD"]
    }
    events = {
      image       = local.images.api
      command     = ["uvicorn", "job_hunting.sse_asgi:app", "--host", "0.0.0.0", "--port", "8001"]
      port        = 8001
      cpu         = "1"
      memory      = "512Mi"
      min_scale   = 1
      max_scale   = 2
      uses_db     = true
      health_path = "/healthz"
      environment = merge(local.django_common, { SA_SCHEMA_ON_POST_MIGRATE = "False" })
      secret_keys = ["SECRET_KEY", "DATABASE_URL"]
    }
    frontend = {
      image       = local.images.frontend
      command     = null # nginx default
      port        = 80
      cpu         = "1"
      memory      = "512Mi" # Cloud Run rejects <512Mi when CPU is always-allocated
      min_scale   = 0
      max_scale   = 2
      uses_db     = false
      health_path = "/"
      # Search indexing: this is PROD (careercaddy.online) → indexable, so
      # ROBOTS_NOINDEX is left UNSET. The frontend image is SHARED with the racknerd
      # dev env (careercaddy.dev), which sets ROBOTS_NOINDEX=true to stay unindexed
      # (nginx honors it: X-Robots-Tag: noindex + robots.txt Disallow: /).
      #
      # Same-origin reverse-proxy upstreams: the frontend nginx proxies /api,
      # /api/v1/events, /mcp to these services so the browser is same-origin (no
      # CORS). Built from the project NUMBER (a data source) + region — NOT
      # lb[...].uri: api/events/mcp share this for_each resource, so referencing
      # their .uri would be a dependency cycle (same reason api_base_url is a
      # computed string, not a service ref). nginx rewrites Host to the run.app
      # host → Cloud Run routes + Django's .run.app ALLOWED_HOSTS accepts.
      environment = {
        API_UPSTREAM    = "https://api-${data.google_project.this.number}.${var.region}.run.app"
        EVENTS_UPSTREAM = "https://events-${data.google_project.this.number}.${var.region}.run.app"
        MCP_UPSTREAM    = "https://mcp-${data.google_project.this.number}.${var.region}.run.app"
      }
      secret_keys = []
    }
    mcp = {
      image       = local.images.ai
      command     = ["uv", "run", "caddy-public"]
      port        = 8000
      cpu         = "1"
      memory      = "512Mi"
      min_scale   = 0
      max_scale   = 2
      uses_db     = false
      health_path = "/mcp"
      environment = { CC_API_BASE_URL = local.api_base_url, FASTMCP_HOST = "0.0.0.0", FASTMCP_PORT = "8000" }
      secret_keys = []
    }
  }

  common_labels = {
    project     = "career-caddy"
    managed-by  = "terraform"
    environment = "poc"
  }
}
