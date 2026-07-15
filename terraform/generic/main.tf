# One null_resource per Career Caddy component. Metadata lives in `triggers`;
# edges are drawn by referencing another component's `.id` inside triggers, so
# Brainboard renders the real dependency + request-flow graph:
#
#   ingress ─┬─> frontend ─> api
#            ├─> api ─┬─> db
#            │        ├─> screenshots
#            │        ├─> events ─> db / screenshots
#            │        └─> chat ─> api
#            └─> mcp ─> api / screenshots
#   worker ─> db / screenshots
#
# The `local` map at the bottom exposes the same data as a readable output.

# --- Data stores (leaves) ---------------------------------------------------

resource "null_resource" "db" {
  triggers = {
    role    = "database"
    engine  = "postgres"
    version = var.postgres_version
    port    = "5432"
    volume  = "career_caddy_postgres_data"
  }
}

resource "null_resource" "screenshots" {
  triggers = {
    role = "shared-volume"
    path = "/screenshots"
    note = "written by api/events/worker, read by mcp"
  }
}

# --- Application services ----------------------------------------------------

resource "null_resource" "api" {
  triggers = {
    role       = "django-gunicorn-rest"
    image      = "career_caddy_api:${var.image_tag}"
    port       = "8000"
    depends_db = null_resource.db.id
    uses_vol   = null_resource.screenshots.id
    calls_evt  = null_resource.events.id
    calls_chat = null_resource.chat.id
  }
}

resource "null_resource" "events" {
  triggers = {
    role       = "uvicorn-asgi-sse"
    image      = "career_caddy_api:${var.image_tag}"
    port       = "8001"
    depends_db = null_resource.db.id
    uses_vol   = null_resource.screenshots.id
  }
}

resource "null_resource" "worker" {
  triggers = {
    role       = "django-q2-qcluster"
    image      = "career_caddy_api:${var.image_tag}"
    port       = "none"
    depends_db = null_resource.db.id
    uses_vol   = null_resource.screenshots.id
  }
}

resource "null_resource" "frontend" {
  triggers = {
    role      = "ember-spa-nginx"
    image     = "career-caddy-frontend:${var.image_tag}"
    port      = "80"
    calls_api = null_resource.api.id
  }
}

resource "null_resource" "mcp" {
  triggers = {
    role      = "fastmcp-public-tools"
    image     = "career_caddy_ai:${var.image_tag}"
    port      = "8030"
    calls_api = null_resource.api.id
    uses_vol  = null_resource.screenshots.id
  }
}

resource "null_resource" "chat" {
  triggers = {
    role   = "internal-llm-chat"
    image  = "career_caddy_ai:${var.image_tag}"
    port   = "8031"
    public = "false"
    # api forwards to chat (api->chat edge on the api resource). chat also calls
    # api back at request time, but that reverse edge is omitted to keep the
    # graph acyclic — Terraform forbids dependency cycles.
  }
}

# --- Ingress (Caddy reverse-proxy: 3 public hostnames) ----------------------

resource "null_resource" "ingress" {
  triggers = {
    role        = "caddy-reverse-proxy"
    port        = "443"
    host_app    = var.domain
    host_api    = "api.${var.domain}"
    host_mcp    = "mcp.${var.domain}"
    to_frontend = null_resource.frontend.id
    to_api      = null_resource.api.id
    to_mcp      = null_resource.mcp.id
  }
}
