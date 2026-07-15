# Application Load Balancer — the AWS-native replacement for Caddy's reverse
# proxy. Host + path listener rules encode the same routing the Caddy labels do.

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = merge(local.common_tags, { Name = "${local.name}-alb" })
}

# One target group per public service (api, events, frontend, mcp).
resource "aws_lb_target_group" "svc" {
  for_each = local.public_services

  name        = "${local.name}-${each.key}"
  port        = each.value.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path    = each.value.health_path
    matcher = each.value.health_matcher
  }

  tags = merge(local.common_tags, { Name = each.key })
}

# --- TLS certificate covering all three POC hostnames -----------------------

resource "aws_acm_certificate" "main" {
  domain_name               = local.hosts.app
  subject_alternative_names = [local.hosts.api, local.hosts.mcp]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = local.base })
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --- Listeners --------------------------------------------------------------

# HTTP :80 -> permanent redirect to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS :443 — default action serves the SPA (aws.careercaddy.online root).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["frontend"].arn
  }
}

# SSE — /api/v1/events/ must win over the broader /api/* rule (lower priority #).
resource "aws_lb_listener_rule" "app_events" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["events"].arn
  }

  condition {
    host_header {
      values = [local.hosts.app]
    }
  }
  condition {
    path_pattern {
      values = ["/api/v1/events/"]
    }
  }
}

resource "aws_lb_listener_rule" "api_events" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 12

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["events"].arn
  }

  condition {
    host_header {
      values = [local.hosts.api]
    }
  }
  condition {
    path_pattern {
      values = ["/api/v1/events/"]
    }
  }
}

# app host + /api/* + federation paths -> api (same-origin SPA calls).
resource "aws_lb_listener_rule" "app_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["api"].arn
  }

  condition {
    host_header {
      values = [local.hosts.app]
    }
  }
  condition {
    path_pattern {
      values = ["/api/*", "/.well-known/webfinger", "/actors/*", "/activities/*"]
    }
  }
}

# api host (everything else) -> api.
resource "aws_lb_listener_rule" "api_host" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["api"].arn
  }

  condition {
    host_header {
      values = [local.hosts.api]
    }
  }
}

# mcp host -> mcp (FastMCP public tools).
resource "aws_lb_listener_rule" "mcp_host" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 40

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc["mcp"].arn
  }

  condition {
    host_header {
      values = [local.hosts.mcp]
    }
  }
}
