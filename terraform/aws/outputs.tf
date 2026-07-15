output "nameservers" {
  description = "Add these as NS records for `aws` at Namecheap to delegate the POC subdomain."
  value       = aws_route53_zone.poc.name_servers
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer (the alias records point here)."
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "PostgreSQL endpoint (private)."
  value       = aws_db_instance.postgres.endpoint
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "public_urls" {
  description = "Public URLs served by the POC stack."
  value = {
    app = "https://${local.hosts.app}"
    api = "https://${local.hosts.api}"
    mcp = "https://${local.hosts.mcp}"
  }
}
