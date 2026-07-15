# Route53 hosted zone for the POC subdomain. The apex careercaddy.online stays
# at Namecheap; delegate `aws.careercaddy.online` here by adding this zone's NS
# records at Namecheap (see the `nameservers` output + terraform/README.md).

resource "aws_route53_zone" "poc" {
  name = local.base # aws.careercaddy.online
  tags = merge(local.common_tags, { Name = local.base })
}

# Alias records for the three POC hostnames -> ALB.
resource "aws_route53_record" "hosts" {
  for_each = local.hosts

  zone_id = aws_route53_zone.poc.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ACM DNS-validation records (one per distinct domain in the cert).
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.poc.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}
