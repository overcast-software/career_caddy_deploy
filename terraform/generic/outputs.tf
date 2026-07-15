# Human-readable summary of the component graph (role / port / edges).

output "components" {
  description = "Career Caddy components and their outbound edges."
  value = {
    ingress = {
      role  = "caddy-reverse-proxy"
      port  = 443
      hosts = [var.domain, "api.${var.domain}", "mcp.${var.domain}"]
      edges = ["frontend", "api", "mcp"]
    }
    frontend    = { role = "ember-spa-nginx", port = 80, edges = ["api"] }
    api         = { role = "django-gunicorn-rest", port = 8000, edges = ["db", "screenshots", "events", "chat"] }
    events      = { role = "uvicorn-asgi-sse", port = 8001, edges = ["db", "screenshots"] }
    worker      = { role = "django-q2-qcluster", port = 0, edges = ["db", "screenshots"] }
    mcp         = { role = "fastmcp-public-tools", port = 8030, edges = ["api", "screenshots"] }
    chat        = { role = "internal-llm-chat", port = 8031, edges = [] }
    db          = { role = "postgres", port = 5432, edges = [] }
    screenshots = { role = "shared-volume", port = 0, edges = [] }
  }
}
