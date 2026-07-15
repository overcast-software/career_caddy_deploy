locals {
  name     = "career-caddy"
  internal = "${local.name}.internal" # Cloud Map private namespace

  # POC hostnames (subdomain of the apex; prod careercaddy.online is untouched).
  base = "${var.poc_subdomain}.${var.domain_name}" # aws.careercaddy.online
  hosts = {
    app = local.base
    api = "api.${local.base}" # api.aws.careercaddy.online
    mcp = "mcp.${local.base}" # mcp.aws.careercaddy.online
  }

  # Public GHCR images (no auth needed). api/events/worker share the api image;
  # mcp/chat share the ai image.
  images = {
    api      = "ghcr.io/overcast-software/career_caddy_api:${var.image_tag}"
    frontend = "ghcr.io/overcast-software/career-caddy-frontend:${var.image_tag}"
    ai       = "ghcr.io/overcast-software/career_caddy_ai:${var.image_tag}"
  }

  # Internal service-to-service URLs via Cloud Map DNS.
  api_url  = "http://api.${local.internal}:8000"
  chat_url = "http://chat.${local.internal}:8000"

  # Django env shared by api/events/worker (the api image).
  django_common = {
    DEBUG         = "False"
    ALLOWED_HOSTS = "${local.hosts.app},${local.hosts.api},${local.hosts.mcp},localhost,127.0.0.1,api,events,worker"
  }

  # One entry per Fargate service. Faithful to docker-compose.prod.yml:
  #   - api uses the image entrypoint (migrate + gunicorn); events/worker
  #     override entryPoint to bypass entrypoint.sh; mcp/chat use `command`
  #     against the ai image's default entrypoint (matches compose).
  #   - container_port is the ACTUAL listen port (mcp/chat listen on 8000).
  services = {
    api = {
      image          = local.images.api
      entrypoint     = null # image default: entrypoint.sh -> migrate + gunicorn
      command        = null
      container_port = 8000
      public         = true
      discoverable   = true
      mount_shared   = true
      desired_count  = 1
      cpu            = 512
      memory         = 1024
      health_path    = "/api/v1/healthcheck/"
      health_matcher = "200-399"
      environment = merge(local.django_common, {
        CORS_ALLOWED_ORIGINS      = "https://${local.hosts.app}"
        CSRF_TRUSTED_ORIGINS      = "https://${local.hosts.app}"
        FRONTEND_URL              = "https://${local.hosts.app}"
        INSTANCE_ORIGIN           = "https://${local.hosts.app}"
        EMAIL_BACKEND             = "django.core.mail.backends.console.EmailBackend" # POC: no SMTP secrets
        SCRAPING_ENABLED          = "False"
        USE_MCP_BROWSER_AGENT     = "False"
        GUNICORN_WORKERS          = "2"
        GUNICORN_THREADS          = "4"
        SA_SCHEMA_ON_POST_MIGRATE = "True"
        CHAT_SERVICE_URL          = local.chat_url
        SCREENSHOT_DIR            = "/app/screenshots"
      })
      secret_keys = ["SECRET_KEY", "DATABASE_URL"]
    }

    events = {
      image          = local.images.api
      entrypoint     = ["uvicorn"]
      command        = ["job_hunting.sse_asgi:app", "--host", "0.0.0.0", "--port", "8001"]
      container_port = 8001
      public         = true
      discoverable   = true
      mount_shared   = false
      desired_count  = 1
      cpu            = 256
      memory         = 512
      health_path    = "/healthz"
      health_matcher = "200-399"
      environment = merge(local.django_common, {
        SA_SCHEMA_ON_POST_MIGRATE = "False"
      })
      secret_keys = ["SECRET_KEY", "DATABASE_URL"]
    }

    worker = {
      image          = local.images.api
      entrypoint     = ["python"]
      command        = ["manage.py", "qcluster"]
      container_port = 0 # no HTTP
      public         = false
      discoverable   = false
      mount_shared   = true
      desired_count  = 1
      cpu            = 256
      memory         = 512
      health_path    = null
      health_matcher = null
      environment = merge(local.django_common, {
        SA_SCHEMA_ON_POST_MIGRATE = "False"
        Q_WORKERS                 = "1"
        SCRAPING_ENABLED          = "False"
        USE_MCP_BROWSER_AGENT     = "False"
        CHAT_SERVICE_URL          = local.chat_url
        SCREENSHOT_DIR            = "/app/screenshots"
        EMAIL_BACKEND             = "django.core.mail.backends.console.EmailBackend"
      })
      secret_keys = ["SECRET_KEY", "DATABASE_URL"]
    }

    frontend = {
      image          = local.images.frontend
      entrypoint     = null # nginx default
      command        = null
      container_port = 80
      public         = true
      discoverable   = true
      mount_shared   = false
      desired_count  = 1
      cpu            = 256
      memory         = 256
      health_path    = "/"
      health_matcher = "200-399"
      environment    = {}
      secret_keys    = []
    }

    mcp = {
      image          = local.images.ai
      entrypoint     = null
      command        = ["uv", "run", "caddy-public"]
      container_port = 8000
      public         = true
      discoverable   = true
      mount_shared   = false
      desired_count  = 1
      cpu            = 256
      memory         = 512
      health_path    = "/mcp"
      health_matcher = "200-499" # /mcp returns 401 unauthenticated = "up"
      environment = {
        CC_API_BASE_URL = local.api_url
        FASTMCP_HOST    = "0.0.0.0"
        FASTMCP_PORT    = "8000"
      }
      secret_keys = []
    }

    chat = {
      image          = local.images.ai
      entrypoint     = null
      command        = ["uv", "run", "caddy-chat"]
      container_port = 8000
      public         = false # internal only, no ALB
      discoverable   = true
      mount_shared   = false
      desired_count  = 1
      cpu            = 512
      memory         = 1024
      health_path    = null
      health_matcher = null
      environment = {
        CC_API_BASE_URL = local.api_url
        CHAT_HOST       = "0.0.0.0"
        CHAT_PORT       = "8000"
        CHAT_MODEL      = "openai:gpt-4o-mini"
      }
      secret_keys = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
    }
  }

  # Services that terminate on the ALB.
  public_services = { for k, v in local.services : k => v if v.public }
  # Services that register in Cloud Map for internal DNS.
  discoverable_services = { for k, v in local.services : k => v if v.discoverable }

  common_tags = {
    Project     = "career-caddy"
    ManagedBy   = "terraform"
    Environment = "poc"
    Note        = "aws-poc-subdomain"
  }
}
