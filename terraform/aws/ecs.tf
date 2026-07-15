# ECS Fargate cluster running one service per compose container.

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, { Name = local.name })
}

# --- IAM --------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Let the execution role pull the Secrets Manager values it injects into tasks.
data "aws_iam_policy_document" "secrets_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for arn in values(local.secret_arns) : arn]
  }
}

resource "aws_iam_role_policy" "secrets_read" {
  name   = "${local.name}-secrets-read"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.common_tags
}

# --- Logs -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "svc" {
  for_each          = local.services
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = 14
  tags              = merge(local.common_tags, { Name = each.key })
}

# --- Internal service discovery (Cloud Map) ---------------------------------

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = local.internal
  description = "Internal DNS for Career Caddy ECS services."
  vpc         = aws_vpc.main.id
  tags        = local.common_tags
}

resource "aws_service_discovery_service" "svc" {
  for_each = local.discoverable_services

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      type = "A"
      ttl  = 10
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}

# --- Task definitions (generic; driven by local.services) -------------------

resource "aws_ecs_task_definition" "svc" {
  for_each = local.services

  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name        = each.key
        image       = each.value.image
        essential   = true
        environment = [for k, v in each.value.environment : { name = k, value = v }]
        secrets = [
          for k in each.value.secret_keys : { name = k, valueFrom = local.secret_arns[k] }
          if contains(keys(local.secret_arns), k)
        ]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.svc[each.key].name
            "awslogs-region"        = var.region
            "awslogs-stream-prefix" = each.key
          }
        }
      },
      each.value.entrypoint != null ? { entryPoint = each.value.entrypoint } : {},
      each.value.command != null ? { command = each.value.command } : {},
      each.value.container_port > 0 ? {
        portMappings = [{ containerPort = each.value.container_port, protocol = "tcp" }]
      } : {},
      each.value.mount_shared ? {
        mountPoints = [{ sourceVolume = "screenshots", containerPath = "/app/screenshots" }]
      } : {},
    )
  ])

  dynamic "volume" {
    for_each = each.value.mount_shared ? [1] : []
    content {
      name = "screenshots"
      efs_volume_configuration {
        file_system_id     = aws_efs_file_system.screenshots.id
        transit_encryption = "ENABLED"
      }
    }
  }

  tags = merge(local.common_tags, { Name = each.key })
}

# --- Services ---------------------------------------------------------------

resource "aws_ecs_service" "svc" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  # Public services register with their ALB target group.
  dynamic "load_balancer" {
    for_each = each.value.public ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.svc[each.key].arn
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  # Discoverable services register with Cloud Map for internal DNS.
  dynamic "service_registries" {
    for_each = each.value.discoverable ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.svc[each.key].arn
    }
  }

  depends_on = [aws_lb_listener.https]

  tags = merge(local.common_tags, { Name = each.key })
}
