// terraform/dns_tls.tf
// Route 53 + ACM + HTTPS listener for the ALB.
//
// Why:
//   - Provide a stable DNS name (api.<env>.<domain>) pointing at the ALB.
//   - Issue an ACM certificate validated via Route 53 DNS records.
//   - Terminate TLS on the ALB with a modern TLS 1.2+ policy on port 443
//     and redirect every request on port 80 to HTTPS.
//
// Guarded by var.enable_public_tls so the stack can still be brought up in
// environments where no real domain is available (e.g. local dev, sandbox).
//
// ASSUMPTION: The Route 53 public hosted zone for var.public_domain already
// exists in the same AWS account. Domain registration and zone creation are
// out of scope for this Terraform stack.

variable "enable_public_tls" {
  description = "Enable Route 53 record + ACM cert + HTTPS listener + HTTP->HTTPS redirect."
  type        = bool
  default     = false
}

variable "public_domain" {
  description = "Apex or parent domain already hosted in Route 53 (e.g. example.com)."
  type        = string
  default     = ""
}

variable "public_subdomain" {
  description = "Subdomain for this environment (e.g. api, dev.api, staging.api)."
  type        = string
  default     = "api"
}

locals {
  public_fqdn = var.enable_public_tls ? "${var.public_subdomain}.${var.public_domain}" : ""
}

data "aws_route53_zone" "public" {
  count        = var.enable_public_tls ? 1 : 0
  name         = var.public_domain
  private_zone = false
}

// ─── ACM certificate (DNS-validated) ─────────────────────────────────────────
resource "aws_acm_certificate" "alb" {
  count             = var.enable_public_tls ? 1 : 0
  domain_name       = local.public_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-alb-cert"
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = var.enable_public_tls ? {
    for dvo in aws_acm_certificate.alb[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "alb" {
  count                   = var.enable_public_tls ? 1 : 0
  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

// ─── ALB alias record ────────────────────────────────────────────────────────
resource "aws_route53_record" "alb" {
  count   = var.enable_public_tls ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = local.public_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

// ─── HTTPS listener (TLS 1.2+) ───────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  count             = var.enable_public_tls ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"route not found. Use /service1 or /service2\"}"
      status_code  = "404"
    }
  }

  tags = {
    Name = "${var.project_name}-https-listener"
  }
}

// HTTPS forwarding rules mirror the HTTP listener rules so both work during
// a TLS cutover and the HTTP listener can be flipped to a redirect later.
resource "aws_lb_listener_rule" "https_service1" {
  count        = var.enable_public_tls ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service1.arn
  }

  condition {
    path_pattern {
      values = ["/service1", "/service1/*"]
    }
  }
}

resource "aws_lb_listener_rule" "https_service2" {
  count        = var.enable_public_tls ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service2.arn
  }

  condition {
    path_pattern {
      values = ["/service2", "/service2/*"]
    }
  }
}

// ─── HTTP -> HTTPS redirect (optional) ───────────────────────────────────────
// When TLS is enabled we attach a high-priority redirect rule to the existing
// HTTP:80 listener so every plain HTTP request is upgraded to HTTPS.
resource "aws_lb_listener_rule" "http_to_https_redirect" {
  count        = var.enable_public_tls ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

output "public_fqdn" {
  description = "Public DNS name for the ALB (empty string when TLS is disabled)."
  value       = local.public_fqdn
}
