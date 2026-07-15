# Data stores: RDS PostgreSQL, EFS (shared screenshots), Secrets Manager.

# --- Generated secrets (live in state + Secrets Manager, never in source) ----

resource "random_password" "db" {
  length  = 32
  special = false # keep DATABASE_URL free of chars needing URL-encoding
}

resource "random_password" "secret_key" {
  length  = 64
  special = false # Django SECRET_KEY — alphanumeric is fine
}

# --- RDS PostgreSQL (replaces the `db` compose service) ---------------------

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = [for s in aws_subnet.private : s.id]
  tags       = merge(local.common_tags, { Name = "${local.name}-db" })
}

resource "aws_db_instance" "postgres" {
  identifier     = "${local.name}-postgres"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  db_name  = "job_hunting"
  username = "postgres"
  password = random_password.db.result

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true
  storage_type          = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false
  publicly_accessible    = false

  skip_final_snapshot = true # POC — no lingering snapshot on destroy

  tags = merge(local.common_tags, { Name = "${local.name}-postgres" })
}

# --- EFS shared screenshots volume (api <-> worker) -------------------------

resource "aws_efs_file_system" "screenshots" {
  creation_token = "${local.name}-screenshots"
  encrypted      = true
  tags           = merge(local.common_tags, { Name = "${local.name}-screenshots" })
}

resource "aws_efs_mount_target" "screenshots" {
  for_each        = aws_subnet.private
  file_system_id  = aws_efs_file_system.screenshots.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs.id]
}

# --- Secrets Manager --------------------------------------------------------
# Values are generated (db password, secret key) or passed via optional vars.
# DATABASE_URL is assembled from the RDS endpoint + generated password.

locals {
  secret_values = merge(
    {
      SECRET_KEY   = random_password.secret_key.result
      DATABASE_URL = "postgresql://postgres:${random_password.db.result}@${aws_db_instance.postgres.address}:5432/job_hunting"
    },
    var.openai_api_key != "" ? { OPENAI_API_KEY = var.openai_api_key } : {},
    var.anthropic_api_key != "" ? { ANTHROPIC_API_KEY = var.anthropic_api_key } : {},
  )
}

resource "aws_secretsmanager_secret" "app" {
  for_each = local.secret_values
  name     = "${local.name}/${each.key}"
  tags     = merge(local.common_tags, { Name = "${local.name}-${lower(each.key)}" })
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each      = local.secret_values
  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = each.value
}

locals {
  # key -> secret ARN, for ECS `secrets` valueFrom injection.
  secret_arns = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}
